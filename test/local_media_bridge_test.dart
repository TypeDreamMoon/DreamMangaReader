import 'dart:io';

import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:dream_manga_reader/core/platform/local_media_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';
const _kotlinRoot = 'android/app/src/main/kotlin/com/dreammoon/dream_manga_reader';

String _source(String path) => File('$_kotlinRoot/$path').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(LocalMediaBridge.channelName);
  final calls = <MethodCall>[];
  Object? Function(MethodCall call) handler = (_) => null;

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  });

  tearDown(() {
    handler = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 只测桥本身,不碰真的平台通道 —— isAndroid 显式注入。
  LocalMediaBridge android() => LocalMediaBridge(channel: channel, isAndroid: true);

  group('pickDirectory', () {
    test('tree uri 与显示名带回来,类型是 folder', () async {
      handler = (_) => <Object?, Object?>{
            'uri': 'content://com.android.externalstorage.documents/tree/primary%3AMovies',
            'name': 'Movies',
          };

      final picked = await android().pickDirectory();

      expect(calls.single.method, 'pickDirectory');
      expect(calls.single.arguments, isNull);
      expect(picked, isNotNull);
      expect(picked!.uri, contains('tree/primary%3AMovies'));
      expect(picked.name, 'Movies');
      expect(picked.kind, LocalLibraryKind.folder);
    });

    // 取消不是错误(原生给 null),上层据此什么都不做。
    test('用户取消返回 null', () async {
      handler = (_) => null;

      expect(await android().pickDirectory(), isNull);
      expect(calls.single.method, 'pickDirectory');
    });

    test('原生报错原样抛 PlatformException', () async {
      handler = (_) => throw PlatformException(code: 'pick_pending');

      await expectLater(android().pickDirectory(), throwsA(isA<PlatformException>()));
    });
  });

  group('pickFiles', () {
    test('每个文件都带 uri/name/size/mime 回来,类型是 file', () async {
      handler = (_) => <Object?>[
            <Object?, Object?>{
              'uri': 'content://media/external/video/media/41',
              'name': '第一集.mp4',
              'size': 2048,
              'mime': 'video/mp4',
            },
            <Object?, Object?>{
              'uri': 'content://media/external/video/media/42',
              'name': '第二集.mkv',
              // 有的 provider 把 _size 当字符串列,原生原样传过来也要认。
              'size': '4096',
              'mime': 'video/x-matroska',
            },
          ];

      final picked = await android().pickFiles();

      expect(calls.single.method, 'pickFiles');
      expect(picked, hasLength(2));
      expect(picked.first.uri, 'content://media/external/video/media/41');
      expect(picked.first.name, '第一集.mp4');
      expect(picked.first.kind, LocalLibraryKind.file);
      expect(picked.last.name, '第二集.mkv');
    });

    test('一个都没选就是空列表', () async {
      handler = (_) => <Object?>[];

      expect(await android().pickFiles(), isEmpty);
    });

    test('缺 uri 的脏条目被丢掉,不炸整次解析', () async {
      handler = (_) => <Object?>[
            <Object?, Object?>{'name': '没有 uri'},
            <Object?, Object?>{
              'uri': 'content://media/external/video/media/43',
              'name': '好的.mp4',
            },
          ];

      final picked = await android().pickFiles();

      expect(picked, hasLength(1));
      expect(picked.single.name, '好的.mp4');
    });
  });

  group('listChildren', () {
    test('传 treeUri,解析出 uri/name/size/mime/lastModified', () async {
      handler = (_) => <Object?>[
            <Object?, Object?>{
              'uri': 'content://tree/primary%3AMovies/document/primary%3AMovies%2Fa.mp4',
              'name': 'a.mp4',
              'size': 1024,
              'mime': 'video/mp4',
              'lastModified': 1730000000000,
            },
          ];

      final entries = await android()
          .listChildren('content://tree/primary%3AMovies');

      expect(calls.single.method, 'listChildren');
      final arguments = calls.single.arguments as Map;
      expect(arguments['treeUri'], 'content://tree/primary%3AMovies');
      expect(entries, hasLength(1));
      expect(entries.single.name, 'a.mp4');
      expect(entries.single.size, 1024);
      expect(entries.single.mime, 'video/mp4');
      expect(entries.single.lastModified, 1730000000000);
    });

    test('size 是字符串、lastModified 缺失都给得体面', () async {
      handler = (_) => <Object?>[
            <Object?, Object?>{
              'uri': 'content://tree/1/document/2',
              'name': 'b.mkv',
              'size': '8192',
              'mime': 'video/x-matroska',
            },
          ];

      final entries = await android().listChildren('content://tree/1');

      expect(entries.single.size, 8192);
      expect(entries.single.lastModified, 0);
    });

    test('扫描失败时异常照传,不当成空结果', () async {
      handler = (_) => throw PlatformException(code: 'scan_failed');

      await expectLater(
        android().listChildren('content://tree/1'),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('stat', () {
    test('传 uri,把返回解析成条目(返回里没有 uri,用调用方给的)', () async {
      handler = (_) => <Object?, Object?>{
            'name': 'a.mp4',
            'size': 1024,
            'mime': 'video/mp4',
            'lastModified': 1730000000000,
          };

      final entry = await android().stat('content://tree/1/document/2');

      final arguments = calls.single.arguments as Map;
      expect(calls.single.method, 'stat');
      expect(arguments['uri'], 'content://tree/1/document/2');
      expect(entry!.uri, 'content://tree/1/document/2');
      expect(entry.name, 'a.mp4');
      expect(entry.lastModified, 1730000000000);
    });

    // 文件已被删除/授权失效:原生返回 null 表示「不可用」,不能当异常。
    test('原生返回 null 就是 null', () async {
      handler = (_) => null;

      expect(await android().stat('content://tree/1/document/gone'), isNull);
    });
  });

  group('openFd / releaseFd', () {
    test('拿到 fd 和原样的 /proc/self/fd/N', () async {
      handler = (_) => <Object?, Object?>{'fd': 42, 'path': '/proc/self/fd/42'};

      final opened = await android().openFd('content://tree/1/document/2');

      final arguments = calls.single.arguments as Map;
      expect(calls.single.method, 'openFd');
      expect(arguments['uri'], 'content://tree/1/document/2');
      expect(opened.fd, 42);
      // 不做任何 Uri 包装/规范化:播放层自己 Uri.file(path)(规格 §7.2 路线 A)。
      expect(opened.path, '/proc/self/fd/42');
    });

    test('原生回的 fd 残缺就抛,不返回一个坏路径', () async {
      handler = (_) => <Object?, Object?>{'path': ''};

      await expectLater(
        android().openFd('content://tree/1/document/2'),
        throwsA(isA<PlatformException>()),
      );
    });

    // 播放页在异常路径上可能重复释放,桥要幂等 —— Dart 侧直接把 fd 传下去。
    test('releaseFd 只传 fd,重复调也不抛', () async {
      final bridge = android();

      await bridge.releaseFd(42);
      await bridge.releaseFd(42);

      expect(calls.map((call) => call.method),
          everyElement('releaseFd'));
      expect((calls.first.arguments as Map)['fd'], 42);
      expect((calls.last.arguments as Map)['fd'], 42);
    });
  });

  group('deleteTree', () {
    test('把 uri 传下去,失败照抛', () async {
      final bridge = android();

      await bridge.deleteTree('content://tree/1');
      expect(calls.single.method, 'deleteTree');
      expect((calls.single.arguments as Map)['uri'], 'content://tree/1');

      calls.clear();
      handler = (_) => throw PlatformException(code: 'delete_refused');
      await expectLater(
        bridge.deleteTree('content://tree/1'),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('平台守卫', () {
    test('非 Android 每个方法都抛 UnsupportedError,且不碰通道', () async {
      final bridge = LocalMediaBridge(
        channel: channel,
        isAndroid: false,
      );

      await expectLater(bridge.pickDirectory(), throwsUnsupportedError);
      await expectLater(bridge.pickFiles(), throwsUnsupportedError);
      await expectLater(
        bridge.listChildren('content://tree/1'),
        throwsUnsupportedError,
      );
      await expectLater(bridge.stat('content://tree/1'), throwsUnsupportedError);
      await expectLater(
        bridge.openFd('content://tree/1'),
        throwsUnsupportedError,
      );
      await expectLater(bridge.releaseFd(42), throwsUnsupportedError);
      await expectLater(
        bridge.deleteTree('content://tree/1'),
        throwsUnsupportedError,
      );
      // 静默返回空会把「这个平台没有 SAF」伪装成「用户没选」。
      expect(calls, isEmpty);
    });
  });

  group('纯解析', () {
    test('size 是 num 或 String 都认,负数是「不知道」按 0', () {
      expect(parseIntOrZero(1024), 1024);
      expect(parseIntOrZero('1024'), 1024);
      expect(parseIntOrZero(-1), 0);
      expect(parseIntOrZero(null), 0);
      expect(parseIntOrZero('不是数'), 0);
    });

    test('缺字段的条目用默认值补齐', () {
      final entry = parseLocalMediaEntry(
        <Object?, Object?>{'uri': 'content://tree/1/document/2'},
      );

      expect(entry!.name, '');
      expect(entry.mime, '');
      expect(entry.size, 0);
      expect(entry.lastModified, 0);
    });

    test('没有 uri 又不是 stat 就没有条目', () {
      expect(parseLocalMediaEntry(<Object?, Object?>{'name': 'x'}), isNull);
      expect(parseLocalMediaEntry(null), isNull);
      // stat 的返回里没有 uri,兜底用调用方给的那个。
      expect(
        parseLocalMediaEntry(
          <Object?, Object?>{'name': 'x'},
          uri: 'content://tree/1/document/2',
        )!.uri,
        'content://tree/1/document/2',
      );
    });

    test('原生没给名字就用 uri 最后一段', () {
      final picked = parsePickedLocalLocation(
        <Object?, Object?>{
          'uri': 'content://com.android.externalstorage.documents/tree/primary%3AMovies',
        },
        kind: LocalLibraryKind.folder,
      );

      expect(picked!.name, 'primary%3AMovies');
    });
  });

  // 屋风:桥与原生那侧的契约由读源码的测试钉住(见 android_gallery_native_contract_test.dart)。
  group('原生契约', () {
    test('channel 名与方法分发齐全', () {
      final source = _source('local/LocalMediaBridge.kt');

      expect(source, contains('dream_manga_reader/local_media'));
      expect(LocalMediaBridge.channelName, 'dream_manga_reader/local_media');
      // SAF:授权随 uri 走,重启后靠持久授权依然可读。
      expect(source, contains('Intent.ACTION_OPEN_DOCUMENT_TREE'));
      expect(source, contains('Intent.ACTION_OPEN_DOCUMENT'));
      expect(source, contains('takePersistableUriPermission'));
      // 递归扫描 + 递归要能中止(规格 §9)。
      expect(source, contains('buildChildDocumentsUriUsingTree'));
      expect(source, contains('cancelled.get()'));
      // 路线 A:fd 由桥持有,给 Dart 的是进程内 fd 路径。
      expect(source, contains('openFileDescriptor(uri, "r")'));
      expect(source, contains(r'"/proc/self/fd/$fd"'));
      expect(source, contains('openFds[fd] = descriptor'));
      for (final method in const [
        'pickDirectory',
        'pickFiles',
        'listChildren',
        'stat',
        'openFd',
        'releaseFd',
        'deleteTree',
      ]) {
        expect(source, contains('"$method" ->'), reason: '缺方法 $method');
      }
    });

    test('MainActivity 注册、转发结果、销毁时收尾', () {
      final source = _source('MainActivity.kt');

      expect(source, contains('localMediaBridge = LocalMediaBridge(this)'));
      expect(source, contains('localMediaBridge?.onActivityResult('));
      expect(source, contains('localMediaBridge?.dispose()'));

      // SAF 不需要任何存储权限:manifest 里不能多出这两条。
      final manifest = XmlDocument.parse(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      );
      final permissions = manifest
          .findAllElements('uses-permission')
          .map((element) => element.getAttribute('name', namespace: _android))
          .toList();
      expect(permissions, isNot(contains('android.permission.READ_MEDIA_VIDEO')));
      expect(
        permissions,
        isNot(contains('android.permission.MANAGE_EXTERNAL_STORAGE')),
      );
    });
  });
}
