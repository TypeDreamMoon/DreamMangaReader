import 'dart:io';

import 'package:dream_manga_reader/app/app.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/source/source_repository.dart';
import 'package:dream_manga_reader/core/storage/secret_store.dart';
import 'package:dream_manga_reader/core/sync/sync_backend.dart';
import 'package:dream_manga_reader/core/sync/sync_controller.dart';
import 'package:dream_manga_reader/core/sync/sync_data.dart';
import 'package:dream_manga_reader/core/sync/sync_messages.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「打开 App 就自动合并」这条链的整链验证。
///
/// 关键不变量:**本机为空(或本机这一段根本没读出来)时,云端不能被清空**。
/// 这是真丢过数据的场景,所以拿一个内存后端把 pull → 合并 → 应用 → push 整条链
/// 跑完,断言云端**推上去的那份**里收藏还在 —— 只测纯函数测不到这里。
class _MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// 内存里的「云端」:一份 blob + 拉/推次数 + 最后一次推上来的内容。
class _FakeBackend implements SyncBackend {
  _FakeBackend(this.cloud);

  Map<String, dynamic>? cloud;
  int pulls = 0;
  int pushes = 0;
  Map<String, dynamic>? lastPushed;

  @override
  Future<Map<String, dynamic>?> pull() async {
    pulls++;
    return cloud;
  }

  @override
  Future<void> push(Map<String, dynamic> blob) async {
    pushes++;
    lastPushed = blob;
    cloud = blob;
  }

  @override
  Future<SyncTestResult> test() async =>
      SyncTestResult.success(SyncMessage.testWebDavReady);
}

/// `load()` 里的 IamAuth 也读安全存储,而它不走注入的 [SecretStore]。
/// flutter_secure_storage 没有官方测试替身,把它的 MethodChannel 换成内存表。
void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
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

Map<String, dynamic> _favorite(String source, String id, int addedAt) =>
    {'s': source, 'm': id, 't': '$source-$id', 'c': null, 'a': addedAt};

/// 云端的 blob:3 本收藏 + 1 条进度,时间戳比本机(打快照那一刻)老。
Map<String, dynamic> _cloudBlob() => {
      'v': 2,
      'syncedAt': 1000,
      'library': {
        'v': 2,
        'favorites': [
          _favorite('src', '1', 10),
          _favorite('src', '2', 20),
          _favorite('src', '3', 30),
        ],
        'history': {
          'src:1': {
            's': 'src',
            'm': '1',
            't': 'src-1',
            'c': null,
            'lc': 'c1',
            'ln': '第1话',
            'lp': 3,
            'lt': 20,
            'u': 40,
            'ch': const <String, dynamic>{},
          },
        },
      },
    };

List _favoritesOf(Map<String, dynamic>? blob) =>
    (_blobLibrary(blob)['favorites'] as List?) ?? const [];

Map<String, dynamic> _blobLibrary(Map<String, dynamic>? blob) =>
    ((blob?['library'] as Map?) ?? const {}).cast<String, dynamic>();

/// 推上去的那份里有没有「收藏被删」的墓碑(有 = 云端收藏会被抹掉)。
Set<String> _buriedFavorites(Map<String, dynamic>? blob) {
  final raw = _blobLibrary(blob)['favoritesDeleted'];
  return raw is Map ? raw.keys.map((e) => e.toString()).toSet() : const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sync = SyncController.instance;
  late _FakeBackend backend;
  late LibraryStore lib;
  late NovelLibraryStore novels;
  late SourceRepository repo;
  late Directory cache;

  setUp(() async {
    _mockSecureStorage();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    cache = await Directory.systemTemp.createTemp('dmr-auto-sync-');
    backend = _FakeBackend(_cloudBlob());
    sync.debugConfigure(
      secrets: _MemorySecretStore(),
      preferences: await SharedPreferences.getInstance(),
    );
    sync.debugBackendFactory = () => backend;
    sync.debugResetAutoSyncThrottle();
    // WebDAV 的 configured 只要求地址非空 —— 没配过的用户不会有任何自动网络行为,
    // 这也是「默认开」不打扰人的前提(用例里直接给一个地址表示「已经配好了」)。
    sync.backendKind = 'webdav';
    sync.url = 'https://dav.example.com/dav/';
    sync.auto = true;
    sync.autoUploadOn = {};
    sync.syncCategories = {SyncCategory.favorites, SyncCategory.history};
  });

  tearDown(() async {
    sync.debugBackendFactory = null;
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  Future<void> boot({Map<String, Object> prefs = const {}}) async {
    if (prefs.isNotEmpty) {
      SharedPreferences.setMockInitialValues(prefs);
      sync.debugConfigure(
        secrets: _MemorySecretStore(),
        preferences: await SharedPreferences.getInstance(),
      );
    }
    lib = LibraryStore();
    await lib.load();
    novels = NovelLibraryStore();
    await novels.load();
    repo = SourceRepository.forTesting(
      preferences: await SharedPreferences.getInstance(),
      secrets: _MemorySecretStore(),
      cacheDirectory: cache,
    );
  }

  group('开关的默认值', () {
    test('没写过这个键时,打开 App 自动同步是开的', () async {
      await boot();
      await sync.load();
      expect(sync.auto, isTrue, reason: '丢过数据的人最需要的恰恰是「打开就有」');
    });

    test('用户明确关掉过,就不会被默认值打开', () async {
      await boot(prefs: const {'sync.auto': false});
      await sync.load();
      expect(sync.auto, isFalse);
    });
  });

  group('启动自动合并', () {
    test('本机为空 + 云端有收藏:云端不被清空,本机把收藏拿回来', () async {
      await boot();

      await sync.autoSyncOnStart(lib, novels, repo);

      expect(backend.pulls, 1);
      expect(backend.pushes, 1);
      // 云端:3 本收藏原样留着(并集,本机的空不算「删光」)。
      expect(_favoritesOf(backend.lastPushed).length, 3);
      expect(_buriedFavorites(backend.lastPushed), isEmpty,
          reason: '本机为空不能被记成「全删了」的墓碑 —— 墓碑会把云端一起删掉');
      // 本机:合并结果写回来,收藏是真的回来了。
      expect((lib.exportData()['favorites'] as List).length, 3);
      expect(sync.status?.message, SyncMessage.synced);
      expect(sync.status?.favorites, 3);
    });

    test('本机收藏那一段读档失败时,不能把云端收藏当删除', () async {
      await boot(prefs: const {'lib.favorites': '{坏掉的 JSON'});

      expect(lib.favoritesLoadFailed, isTrue, reason: '前提:这一段确实没读出来');
      expect(lib.exportData()['favorites'], isEmpty);

      await sync.autoSyncOnStart(lib, novels, repo);

      expect(_favoritesOf(backend.lastPushed).length, 3,
          reason: '「没读出来」不是「用户删光了」,云端必须原样');
      expect(_buriedFavorites(backend.lastPushed), isEmpty);
      // 顺带把书修回来:合并结果写回本地,这一段从此又能存了。
      expect((lib.exportData()['favorites'] as List).length, 3);
      expect(lib.favoritesLoadFailed, isFalse);
    });
  });

  group('回到前台自动合并', () {
    test('会合并一次,但连着切回来不会每次都拉一整包', () async {
      await boot();

      await sync.autoSyncOnResume(lib, novels, repo);
      expect(backend.pulls, 1, reason: '切回前台算一次「打开 App」');

      await sync.autoSyncOnResume(lib, novels, repo);
      await sync.autoSyncOnResume(lib, novels, repo);
      expect(backend.pulls, 1, reason: '最小间隔内应被节流吞掉');
      expect(SyncController.autoSyncMinGap.inMinutes, greaterThanOrEqualTo(1));
    });

    test('关掉自动同步后,切回前台不联网', () async {
      await boot();
      sync.auto = false;

      await sync.autoSyncOnResume(lib, novels, repo);

      expect(backend.pulls, 0);
      expect(backend.pushes, 0);
    });

    test('没配好后端(地址为空)时不联网', () async {
      await boot();
      sync.url = '';

      await sync.autoSyncOnResume(lib, novels, repo);

      expect(backend.pulls, 0);
    });
  });

  group('变化后自动上传', () {
    test('自动上传走并集:本机为空也不清空云端', () async {
      await boot();

      await sync.uploadNow(
        lib,
        novels,
        repo,
        categories: {SyncCategory.favorites},
        mergeInsteadOfCover: true,
      );

      expect(_favoritesOf(backend.lastPushed).length, 3);
      expect(_buriedFavorites(backend.lastPushed), isEmpty);
    });

    test('本机收藏读档失败时,自动上传根本不推这一类', () async {
      await boot(prefs: const {'lib.favorites': '{坏掉的 JSON'});
      expect(lib.favoritesLoadFailed, isTrue);

      await sync.uploadNow(
        lib,
        novels,
        repo,
        categories: {SyncCategory.favorites},
        mergeInsteadOfCover: true,
      );

      expect(backend.pushes, 0, reason: '读不出来的类别不推,云端原样保留');
      expect(_favoritesOf(backend.cloud).length, 3);
    });

    test('手动「上传」仍然是覆盖语义(用户明确要求的那一种)', () async {
      await boot();

      await sync.uploadNow(lib, novels, repo,
          categories: {SyncCategory.favorites});

      expect(_favoritesOf(backend.lastPushed), isEmpty,
          reason: '覆盖上传 = 用本机这份盖掉云端这一类,这条没被顺手改掉');
    });

    test('手动「上传」遇到读档失败也拒绝推空的', () async {
      await boot(prefs: const {'lib.favorites': '{坏掉的 JSON'});

      final notice = await sync.uploadNow(lib, novels, repo,
          categories: {SyncCategory.favorites});

      expect(notice.message, SyncMessage.localUnreadable);
      expect(backend.pushes, 0);
      expect(_favoritesOf(backend.cloud).length, 3);
    });
  });

  // 「App 外壳 → 生命周期 → 控制器」这段接线:控制器的行为上面已经逐个测过,
  // 这里只证明切前台真的走到了它 —— 真机上的触发源就是这条平台消息。
  group('App 外壳的生命周期接线', () {
    Future<void> lifecycle(WidgetTester tester, String state) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/lifecycle',
          const StringCodec().encodeMessage(state),
          (_) {},
        );

    /// 装上外壳,等启动链跑完(它要过几个插件通道往返,得让真实时间走一段)。
    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const App());
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump();
    }

    testWidgets('切后台再回来:再合并一次', (tester) async {
      await boot();
      await pumpApp(tester);
      expect(backend.pulls, 1, reason: '冷启动那次');

      // 真机上是「过了两分钟又切回来」;测试里直接把节流窗口清掉。
      sync.debugResetAutoSyncThrottle();
      await lifecycle(tester, 'AppLifecycleState.hidden');
      await tester.pump();
      await lifecycle(tester, 'AppLifecycleState.resumed');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump();

      expect(backend.pulls, 2,
          reason: '手机上「打开 App」多数是切回前台,这一次也得合并');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('只是窗口失焦又点回来(中间没离开过):不再合并', (tester) async {
      await boot();
      await pumpApp(tester);
      expect(backend.pulls, 1, reason: '冷启动那次');

      sync.debugResetAutoSyncThrottle();
      await lifecycle(tester, 'AppLifecycleState.inactive');
      await tester.pump();
      await lifecycle(tester, 'AppLifecycleState.resumed');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump();

      expect(backend.pulls, 1, reason: '桌面上点回窗口不是「打开 App」');

      await tester.pumpWidget(const SizedBox());
    });
  });
}
