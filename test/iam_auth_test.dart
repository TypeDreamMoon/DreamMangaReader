// hertz-iam 原生 auth API 客户端:信封解析、错误码、刷新单飞、策略镜像。
//
// 重点测两件一旦写错就很难查的事:
//   1. 刷新是**轮换 + 重放检测**的,并发刷新必须合并成一次 —— 不然第二个请求
//      拿旧 refresh_token 去换,服务端判成重放,整个会话被吊销(3002)。
//   2. 只有「这个 refresh 真的废了」才清登录态。限流、consumer 配置错之类
//      一律当临时故障,否则网关抖一下用户就被踢下线。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/net/iam_auth.dart';

/// 桩适配器:不发真请求,按 [handler] 返回预设响应(与 bangumi_api_test 同一套路)。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);
  final ResponseBody Function(RequestOptions options) handler;

  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _env(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// 成功信封。
ResponseBody _ok([Map<String, dynamic>? data]) =>
    _env(200, {'code': 0, 'msg': 'ok', 'data': data, 'trace_id': 't-1'});

/// 业务失败信封(HTTP 状态与契约里的默认值无关紧要 —— 判定看信封 code)。
ResponseBody _fail(int code, String msg, {int status = 400}) =>
    _env(status, {'code': code, 'msg': msg, 'trace_id': 't-err'});

Map<String, dynamic> _bundle({
  String access = 'access-1',
  String refresh = 'refresh-1',
  int expiresIn = 900,
  String username = 'reader',
}) =>
    {
      'uid': 'u-1',
      'show_id': '10001',
      'username': username,
      'access_token': access,
      'expires_in': expiresIn,
      'refresh_token': refresh,
      'sid': 's-1',
    };

Map<String, dynamic> _bodyOf(RequestOptions o) =>
    (o.data as Map).cast<String, dynamic>();

/// flutter_secure_storage 没有官方的测试替身,直接把它的 MethodChannel 换成
/// 一份内存表。
void _mockSecureStorage() {
  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final store = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'write':
        if (key != null) store[key] = args['value'] as String? ?? '';
        return null;
      case 'read':
        return key == null ? null : store[key];
      case 'delete':
        store.remove(key);
        return null;
      case 'readAll':
        return Map<String, String>.from(store);
      case 'deleteAll':
        store.clear();
        return null;
      case 'containsKey':
        return store.containsKey(key);
      default:
        return null;
    }
  });
}

IamAuth _auth(_StubAdapter adapter) {
  final dio = Dio(BaseOptions(validateStatus: (s) => s != null && s < 500))
    ..httpClientAdapter = adapter;
  final auth = IamAuth(httpClient: dio)
    ..configure(issuer: 'https://iam.test', clientId: 'dream_manga_reader');
  auth.debugSeedTokens();
  return auth;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_mockSecureStorage);

  group('登录 / 注册', () {
    test('密码登录:取信封 data 里的 token,昵称当场就位', () async {
      final adapter = _StubAdapter((_) => _ok(_bundle(username: '梦月')));
      final auth = _auth(adapter);

      await auth.loginPassword(account: 'reader@x.com', password: 'abcd1234');

      expect(auth.isLoggedIn, isTrue);
      expect(auth.username, '梦月',
          reason: 'TokenBundle 自带 username,不该再跑一趟 userinfo');
      expect(auth.uid, 'u-1');
      expect(auth.sid, 's-1');
      expect(await auth.validAccessToken(), 'access-1');
      expect(adapter.calls.single.path, 'https://iam.test/auth/v1/login/password');
    });

    test('登录请求带上 device_id 与 client_id(服务端 requireGrant 要看)', () async {
      final adapter = _StubAdapter((_) => _ok(_bundle()));
      final auth = _auth(adapter);

      await auth.loginPassword(account: 'reader', password: 'abcd1234');

      final body = _bodyOf(adapter.calls.single);
      expect(body['client_id'], 'dream_manga_reader');
      expect(body['device_id'], 'dmr-test');
      expect(body['account'], 'reader', reason: '账号位可填用户名,不只是邮箱');
    });

    test('注册成功直接就是登录态,不必再登一次', () async {
      final adapter = _StubAdapter((_) => _ok(_bundle(username: 'newbie')));
      final auth = _auth(adapter);

      await auth.signup(
        email: 'a@b.com',
        code: '123456',
        username: 'newbie',
        password: 'abcd1234',
      );

      expect(auth.isLoggedIn, isTrue);
      expect(auth.username, 'newbie');
    });

    test('发码带 scene 与语言', () async {
      final adapter = _StubAdapter((_) => _ok());
      final auth = _auth(adapter);

      await auth.sendCode(
          email: ' A@B.com ', scene: IamCodeScene.signup, locale: 'zh');

      final body = _bodyOf(adapter.calls.single);
      expect(body['email'], 'A@B.com', reason: '前后空白要去掉');
      expect(body['scene'], 'signup');
      expect(body['locale'], 'zh');
    });

    test('重设密码不返回 token,保持未登录', () async {
      final adapter = _StubAdapter((_) => _ok());
      final auth = _auth(adapter);

      await auth.resetPassword(
          email: 'a@b.com', code: '123456', newPassword: 'newpass1');

      expect(auth.isLoggedIn, isFalse, reason: '服务端这个接口只回普通信封');
    });
  });

  group('错误码', () {
    Future<IamException> capture(ResponseBody Function() reply) async {
      final auth = _auth(_StubAdapter((_) => reply()));
      try {
        await auth.loginPassword(account: 'a', password: 'b');
      } on IamException catch (e) {
        return e;
      }
      fail('应当抛 IamException');
    }

    test('凭据错误带出契约码与 trace_id', () async {
      final e = await capture(
          () => _fail(IamErr.invalidCredentials, 'invalid account or password',
              status: 401));

      expect(e.code, IamErr.invalidCredentials);
      expect(e.traceId, 't-err', reason: '报障截图能直接对上服务端日志');
    });

    test('client 没注册和没开授权是两个码,不能混成一句「登录失败」', () async {
      expect((await capture(() => _fail(IamErr.unknownConsumer, 'x'))).code,
          IamErr.unknownConsumer);
      expect((await capture(() => _fail(IamErr.invalidGrant, 'x'))).code,
          IamErr.invalidGrant);
    });

    test('业务码优先于 HTTP 状态:200 里的非 0 也是失败', () async {
      final e = await capture(
          () => _env(200, {'code': IamErr.accountExists, 'msg': 'exists'}));

      expect(e.code, IamErr.accountExists);
    });

    // 5xx 按设计是抛 DioException(交给上层当网络故障),不走信封解析。
    // 真正会把非 JSON 喂进解析器的是 4xx:反代的 404 页、WAF 的 403 拦截页。
    test('4xx 回的是 HTML 而不是信封,也不崩', () async {
      final e = await capture(() =>
          ResponseBody.fromString('<html>blocked by waf</html>', 403));
      expect(e.code, IamErr.internal);
    });
  });

  group('刷新', () {
    test('并发刷新只发一次请求(轮换 + 重放检测下这是硬要求)', () async {
      var refreshCalls = 0;
      final adapter = _StubAdapter((o) {
        if (o.path.endsWith('/token/refresh')) refreshCalls++;
        return _ok(_bundle(access: 'access-2', refresh: 'refresh-2'));
      });
      final auth = _auth(adapter)
        ..configure(issuer: 'https://iam.test', clientId: 'c')
        ..debugSeedTokens(access: 'old', refresh: 'refresh-1', expiresAtMs: 0);

      final results = await Future.wait([
        auth.validAccessToken(),
        auth.validAccessToken(),
        auth.validAccessToken(),
      ]);

      expect(refreshCalls, 1,
          reason: '三个调用必须合并 —— 各自拿旧 token 去换会被判重放并吊销会话');
      expect(results, everyElement('access-2'));
    });

    test('刷新后换新的 refresh_token,下次用新的', () async {
      final seen = <String>[];
      final adapter = _StubAdapter((o) {
        seen.add(_bodyOf(o)['refresh_token'] as String);
        return _ok(_bundle(access: 'a${seen.length}', refresh: 'r${seen.length}'));
      });
      final auth = _auth(adapter)
        ..debugSeedTokens(refresh: 'r0', expiresAtMs: 0);

      await auth.validAccessToken();
      auth.debugSeedTokens(
          access: null, refresh: 'r1', expiresAtMs: 0); // 模拟再次过期
      await auth.validAccessToken();

      expect(seen, ['r0', 'r1'], reason: '轮换后必须用服务端给的新 token');
    });

    test('refresh 失效 / 重放 → 清登录态', () async {
      for (final code in [IamErr.invalidToken, IamErr.refreshReused]) {
        final auth = _auth(_StubAdapter((_) => _fail(code, 'gone', status: 401)))
          ..debugSeedTokens(refresh: 'r0', expiresAtMs: 0);

        expect(await auth.validAccessToken(), isNull);
        expect(auth.isLoggedIn, isFalse, reason: '码 $code 应当要求重新登录');
      }
    });

    test('限流 / consumer 配错不该把人踢下线', () async {
      for (final code in [IamErr.rateLimited, IamErr.unknownConsumer]) {
        final auth = _auth(_StubAdapter((_) => _fail(code, 'later', status: 429)))
          ..debugSeedTokens(refresh: 'r0', expiresAtMs: 0);

        expect(await auth.validAccessToken(), isNull);
        expect(auth.isLoggedIn, isTrue,
            reason: '码 $code 是临时故障,登录态要留着下次再试');
      }
    });

    test('网络异常保留登录态', () async {
      final auth = _auth(_StubAdapter((o) => throw DioException(
          requestOptions: o, type: DioExceptionType.connectionError)))
        ..debugSeedTokens(refresh: 'r0', expiresAtMs: 0);

      expect(await auth.validAccessToken(), isNull);
      expect(auth.isLoggedIn, isTrue);
    });

    test('access 还没过期就不刷', () async {
      final adapter = _StubAdapter((_) => _ok(_bundle()));
      final auth = _auth(adapter)
        ..debugSeedTokens(
            access: 'still-good',
            refresh: 'r0',
            expiresAtMs:
                DateTime.now().millisecondsSinceEpoch + 600 * 1000);

      expect(await auth.validAccessToken(), 'still-good');
      expect(adapter.calls, isEmpty);
    });
  });

  group('策略镜像(与服务端 validation.go / password.go 对齐)', () {
    test('用户名:字母开头,3~32 位,字母数字下划线', () {
      expect(IamAuth.isValidUsername('abc'), isTrue);
      expect(IamAuth.isValidUsername('a_1'), isTrue);
      expect(IamAuth.isValidUsername('a' * 32), isTrue);
      expect(IamAuth.isValidUsername('ab'), isFalse, reason: '太短');
      expect(IamAuth.isValidUsername('a' * 33), isFalse, reason: '太长');
      expect(IamAuth.isValidUsername('1abc'), isFalse, reason: '数字开头');
      expect(IamAuth.isValidUsername('_abc'), isFalse, reason: '下划线开头');
      expect(IamAuth.isValidUsername('a-bc'), isFalse, reason: '连字符不允许');
      expect(IamAuth.isValidUsername('读者名'), isFalse, reason: '仅 ASCII');
    });

    test('密码:8~72 位且至少各有一个字母和数字', () {
      expect(IamAuth.isValidPassword('abcd1234'), isTrue);
      expect(IamAuth.isValidPassword('abc12'), isFalse, reason: '太短');
      expect(IamAuth.isValidPassword('abcdefgh'), isFalse, reason: '没有数字');
      expect(IamAuth.isValidPassword('12345678'), isFalse, reason: '没有字母');
      expect(IamAuth.isValidPassword('${'a' * 71}1'), isTrue);
      expect(IamAuth.isValidPassword('${'a' * 72}1'), isFalse,
          reason: '超过 bcrypt 的 72 上限');
    });

    test('邮箱形状', () {
      expect(IamAuth.isEmail('a@b.com'), isTrue);
      expect(IamAuth.isEmail('a@b'), isFalse);
      expect(IamAuth.isEmail('a b@c.com'), isFalse);
    });
  });
}
