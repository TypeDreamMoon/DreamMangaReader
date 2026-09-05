import 'dart:io';

import 'package:dream_manga_reader/core/net/app_proxy.dart';
import 'package:dream_manga_reader/core/net/image_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubResponse implements FileServiceResponse {
  @override
  Stream<List<int>> get content => const Stream.empty();
  @override
  int? get contentLength => 0;
  @override
  String? get eTag => null;
  @override
  String get fileExtension => '.jpg';
  @override
  int get statusCode => 200;
  @override
  DateTime get validTill => DateTime.now();
}

class _StubService extends FileService {
  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async =>
      _StubResponse();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // AppProxy.refresh 会写 HttpOverrides.global(进程级),别把它留给后面的测试。
  tearDown(() {
    HttpOverrides.global = null;
  });

  group('parse', () {
    test('裸 host:port 按 HTTP 代理处理', () {
      final e = AppProxy.parse('127.0.0.1:7890').endpoint!;
      expect(e.scheme, ProxyScheme.http);
      expect(e.host, '127.0.0.1');
      expect(e.port, 7890);
      expect(e.hasCredentials, isFalse);
      expect(e.directive, 'PROXY 127.0.0.1:7890');
    });

    test('带 scheme 和尾斜杠也认', () {
      final e = AppProxy.parse('  http://proxy.corp:3128/  ').endpoint!;
      expect(e.hostPort, 'proxy.corp:3128');
    });

    test('user:pass@host 拆成凭据,不再被当主机名', () {
      final e = AppProxy.parse('http://alice:s3cret@proxy.corp:8080').endpoint!;
      expect(e.host, 'proxy.corp');
      expect(e.port, 8080);
      expect(e.username, 'alice');
      expect(e.password, 's3cret');
      // dart:io 从 PROXY 指令里的 userinfo 抢先发 Basic 认证(明文转发和
      // https 的 CONNECT 隧道都发)。
      expect(e.directive, 'PROXY alice:s3cret@proxy.corp:8080');
      // 展示/日志用的串不带密码。
      expect(e.hostPort, 'proxy.corp:8080');
    });

    test('百分号编码的账密会解码', () {
      final e = AppProxy.parse('http://a%40b:p%3Aw@h:1080').endpoint!;
      expect(e.username, 'a@b');
      expect(e.password, 'p:w');
    });

    test('socks 明确拒绝,而不是当 HTTP 代理连过去', () {
      for (final raw in ['socks5://127.0.0.1:1080', 'socks4://h:9', 'socks5h://h:9']) {
        final r = AppProxy.parse(raw);
        expect(r.ok, isFalse, reason: raw);
        expect(r.error, ProxyParseError.socksUnsupported, reason: raw);
      }
    });

    test('空串和垃圾串各有各的错误码', () {
      expect(AppProxy.parse('   ').error, ProxyParseError.empty);
      expect(AppProxy.parse('ftp://h:21').error, ProxyParseError.malformed);
      expect(AppProxy.parse('http://:8080').error, ProxyParseError.malformed);
      expect(AppProxy.parse('http://h:99999').error, ProxyParseError.badPort);
    });

    test('缺端口时按 URL 默认端口', () {
      expect(AppProxy.parse('proxy.corp').endpoint!.port, 80);
      expect(AppProxy.parse('https://proxy.corp').endpoint!.port, 443);
    });
  });

  group('no_proxy', () {
    test('本机地址永远直连', () {
      for (final h in ['localhost', '127.0.0.1', '::1', 'nas.local']) {
        expect(AppProxy.shouldBypass(h, const []), isTrue, reason: h);
      }
    });

    test('名单支持精确、子域和通配', () {
      final list = AppProxy.parseNoProxy('example.com, .corp.com ,10.0.0.5');
      expect(AppProxy.shouldBypass('example.com', list), isTrue);
      expect(AppProxy.shouldBypass('api.corp.com', list), isTrue);
      expect(AppProxy.shouldBypass('corp.com', list), isTrue);
      expect(AppProxy.shouldBypass('10.0.0.5', list), isTrue);
      expect(AppProxy.shouldBypass('notexample.com', list), isFalse);
      expect(AppProxy.shouldBypass('google.com', list), isFalse);
      expect(AppProxy.shouldBypass('google.com', AppProxy.parseNoProxy('*')),
          isTrue);
    });

    test('大小写不敏感', () {
      final list = AppProxy.parseNoProxy('CORP.com');
      expect(AppProxy.shouldBypass('api.corp.COM', list), isTrue);
    });
  });

  group('android system proxy', () {
    const channel = MethodChannel('dream_manga_reader/system_proxy');

    void stub(Object? Function() reply) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getSystemProxy');
        return reply();
      });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('原生返回的 host/port/排除名单规整成端点', () async {
      stub(() => <String, Object?>{
            'host': '192.168.1.2',
            'port': 8888,
            'exclusions': ['localhost', ' .corp.com ', ''],
          });

      final (proxy, exclusions) = await AppProxy.readAndroidSystemProxy();
      expect(proxy, '192.168.1.2:8888');
      expect(exclusions, ['localhost', '.corp.com']);
      expect(AppProxy.parse(proxy!).endpoint!.port, 8888);
    });

    test('没有系统代理 / 字段不完整时当直连', () {
      expect(AppProxy.androidSystemProxyFrom(null).$1, isNull);
      expect(AppProxy.androidSystemProxyFrom(const {'port': 8080}).$1, isNull);
      expect(
        AppProxy.androidSystemProxyFrom(const {'host': 'h', 'port': 0}).$1,
        isNull,
      );
      expect(
        AppProxy.androidSystemProxyFrom(const {'host': '  ', 'port': 8080}).$1,
        isNull,
      );
    });

    test('桥没注册(老 APK)不抛,退回直连', () async {
      // 不 stub → MissingPluginException。
      final (proxy, exclusions) = await AppProxy.readAndroidSystemProxy();
      expect(proxy, isNull);
      expect(exclusions, isEmpty);
    });

    test('原生侧确实注册了同名 channel', () {
      final bridge = File(
        'android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/'
        'net/SystemProxyBridge.kt',
      ).readAsStringSync();
      expect(bridge, contains('"dream_manga_reader/system_proxy"'));
      expect(bridge, contains('"getSystemProxy"'));
      expect(bridge, contains('defaultProxy'));
      expect(bridge, contains('http.proxyHost'));

      final activity = File(
        'android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/'
        'MainActivity.kt',
      ).readAsStringSync();
      expect(activity, contains('SystemProxyBridge(this)'));
      expect(activity, contains('systemProxyBridge?.dispose()'));
    });
  });

  group('proxy generation', () {
    test('每次 refresh 递增,让长命 client 知道自己过期了', () async {
      final before = AppProxy.generation;
      await AppProxy.setOverride('DIRECT');
      expect(AppProxy.generation, greaterThan(before));
      final middle = AppProxy.generation;
      await AppProxy.setOverride('127.0.0.1:7890');
      expect(AppProxy.generation, greaterThan(middle));
    });

    test('手动代理落到 endpoint,current 只给 host:port', () async {
      await AppProxy.setOverride('http://bob:pw@127.0.0.1:7890');
      expect(AppProxy.current, '127.0.0.1:7890');
      expect(AppProxy.endpoint!.username, 'bob');
      expect(AppProxy.endpoint!.directive, 'PROXY bob:pw@127.0.0.1:7890');
    });

    test('存下来的非法代理当直连,不把乱码塞进 findProxy', () async {
      // dart:io 的 findProxy 收到解析不了的字符串会直接抛 HttpException,
      // 每个请求都炸——宁可退回直连。
      await AppProxy.setOverride('socks5://127.0.0.1:1080');
      expect(AppProxy.endpoint, isNull);
      expect(AppProxy.current, isNull);
    });

    test('直连名单跟着覆盖一起持久化', () async {
      await AppProxy.setOverride('127.0.0.1:7890', noProxy: '.corp.com');
      expect(AppProxy.noProxy, '.corp.com');
      expect(AppProxy.shouldBypass('api.corp.com'), isTrue);
      expect(AppProxy.shouldBypass('google.com'), isFalse);
    });
  });

  group('image file service', () {
    test('同一代理世代下复用同一个下载器', () async {
      final created = <FileService>[];
      final service = ProxyAwareImageService(createDelegate: () {
        final stub = _StubService();
        created.add(stub);
        return stub;
      });

      await service.get('https://example.com/a.jpg');
      await service.get('https://example.com/b.jpg');

      expect(created, hasLength(1));
    });

    test('改了代理之后重建下载器,不再走旧代理', () async {
      final created = <FileService>[];
      final service = ProxyAwareImageService(createDelegate: () {
        final stub = _StubService();
        created.add(stub);
        return stub;
      });

      await AppProxy.setOverride('127.0.0.1:7890');
      await service.get('https://example.com/a.jpg');
      expect(created, hasLength(1));

      // HttpClient 只在构造那一刻读 HttpOverrides.global,所以改代理必须换 client。
      await AppProxy.setOverride('DIRECT');
      await service.get('https://example.com/b.jpg');
      expect(created, hasLength(2));
      expect(created[0], isNot(same(created[1])));
    });
  });
}
