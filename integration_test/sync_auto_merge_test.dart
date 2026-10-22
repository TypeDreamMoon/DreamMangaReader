// 真机 / 模拟器上的端到端:真 App 外壳 + 真 SharedPreferences + 真 HTTP。
//
// 讲的是一个用户故事:
//   ① 设备 A 把 3 本收藏同步上云端;
//   ② 这台机器数据没了(重装 / 清数据),只把 WebDAV 地址填回来 ——
//      打开 App 应该自动把 3 本并回来,**而且云端不能被清空**;
//   ③ 之后另一台设备又加了 1 本,切回前台应该再并一次。
//
// 跑法(先起那个假云端):
//   node Scripts/e2e_webdav.mjs 8099
//   flutter test integration_test/sync_auto_merge_test.dart -d emulator-5554
//
// 断言打在 **store** 上而不是界面文字上:书架会按「同作品」折叠同名卡片
// (见 core/source/title_match.dart),数界面卡片数不稳,store 才是事实。
import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/app/app.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/library/update_tracker.dart';
import 'package:dream_manga_reader/core/source/source_repository.dart';
import 'package:dream_manga_reader/core/sync/sync_controller.dart';
import 'package:dream_manga_reader/core/sync/sync_data.dart';
import 'package:dream_manga_reader/core/sync/sync_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 宿主机上的假云端。模拟器走 10.0.2.2 到宿主机;真机换成本机局域网 IP。
const _server = String.fromEnvironment('SYNC_E2E_URL',
    defaultValue: 'http://10.0.2.2:8099/');

/// 同步文件在假云端上的地址。用 [Uri.resolve] 拼,别自己加斜杠 ——
/// `baseUrl` 结尾本来就带一个,拼错了就是 404(而且看起来像「没推上去」)。
final _syncUri = Uri.parse(_server).resolve('DreamMangaReader/sync.json');
final _resetUri = Uri.parse(_server).resolve('_reset');

Future<Map<String, dynamic>?> _cloudBlob() async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(_syncUri);
    final response = await request.close();
    final body = (await response.transform(utf8.decoder).join()).trim();
    if (response.statusCode == 404 || body.isEmpty) return null;
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<List<dynamic>> _cloudFavorites() async {
  final library = (await _cloudBlob())?['library'];
  final favorites = library is Map ? library['favorites'] : null;
  return favorites is List ? favorites : const [];
}

/// 另一台设备直接改云端(不带 If-Match = 无条件写,等价于别的客户端覆盖上去了)。
Future<void> _putCloud(Map<String, dynamic> blob) async {
  final client = HttpClient();
  try {
    final request = await client.putUrl(_syncUri);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(blob));
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 200, reason: '假云端应该收下这份 blob');
  } finally {
    client.close(force: true);
  }
}

Future<void> _resetCloud() async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(_resetUri);
    final response = await request.close();
    await response.drain<void>();
    // 断言一下:地址拼错了会静默 404,而「没清干净」会让后面的断言变得没意义。
    expect(response.statusCode, 204, reason: '假云端没被清空(地址不对?)');
  } finally {
    client.close(force: true);
  }
}

/// 平台生命周期消息:和系统真正发过来的那条走同一条路。
Future<void> _lifecycle(WidgetTester tester, String state) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/lifecycle',
      const StringCodec().encodeMessage(state),
      (_) {},
    );

/// 泵到条件成立为止(集成测试是真时钟,真实 I/O 在此期间正常推进)。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 30),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时:$reason');
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Map<String, dynamic> _favorite(String id, String title, int addedAt) =>
    {'s': 'e2e', 'm': id, 't': title, 'c': null, 'a': addedAt};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final sync = SyncController.instance;

  testWidgets('重装后的机器打开 App:云端收藏并回来,云端也不被清空', (tester) async {
    await _resetCloud();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear(); // 「这台机器数据没了」的起点

    // ---- ① 设备 A:真 client、真 HTTP,把 3 本收藏推到假云端 -----------------
    final libA = LibraryStore();
    await libA.load();
    for (var i = 1; i <= 3; i++) {
      libA.toggleFavorite(FavoriteEntry(
        sourceId: 'e2e',
        mangaId: '$i',
        title: 'E2E 作品 $i',
        addedAt: i,
      ));
    }
    final novelsA = NovelLibraryStore();
    await novelsA.load();
    sync.backendKind = 'webdav';
    sync.url = _server;
    sync.username = 'e2e';
    sync.password = 'e2e';
    await sync.uploadNow(
      libA,
      novelsA,
      SourceRepository.instance,
      categories: {SyncCategory.favorites},
    );
    expect((await _cloudFavorites()).length, 3, reason: '云端该有 3 本了');
    libA.dispose();
    novelsA.dispose();

    // ---- ② 换台「干净」的机器:配置只剩地址,自动开关从没写过 ---------------
    await prefs.clear();
    sync.debugResetAutoSyncThrottle();
    await sync.load();
    expect(sync.auto, isTrue, reason: '没写过这个键,默认就该是开的');
    sync.url = _server; // 用户在新机器上重新填了地址
    sync.username = 'e2e';
    sync.password = 'e2e';
    // 追更检查会拿这两本假收藏去真源里查,和本次要验证的事无关。
    LibraryUpdateTracker.instance.autoCheck = false;
    await SourceRepository.instance.load();

    // ---- ③ 打开 App:启动链自己合并 ----------------------------------------
    await tester.pumpWidget(const App());
    await _pumpUntil(
      tester,
      () => sync.status?.message == SyncMessage.synced,
      reason: '启动自动合并没跑完(status=${sync.status})',
    );

    final lib = LibraryScope.of(tester.element(find.byType(MaterialApp)));
    expect(lib.favorites.length, 3, reason: '云端收藏要并回本机');
    expect(lib.isFavorite('e2e', '1'), isTrue);
    expect((await _cloudFavorites()).length, 3, reason: '本机为空不能清空云端');

    // ---- ④ 另一台设备又加了 1 本 → 切回前台该再并一次 -----------------------
    final blob = (await _cloudBlob())!;
    final library = (blob['library'] as Map).cast<String, dynamic>();
    library['favorites'] = [
      ...(library['favorites'] as List),
      _favorite('4', 'E2E 作品 4', 4),
    ];
    await _putCloud(blob);
    expect((await _cloudFavorites()).length, 4);

    // 真机上是「过了一阵子又切回来」;测试里直接清掉节流窗口。
    sync.debugResetAutoSyncThrottle();
    await _lifecycle(tester, 'AppLifecycleState.hidden');
    await tester.pump();
    await _lifecycle(tester, 'AppLifecycleState.resumed');
    await _pumpUntil(
      tester,
      () => lib.favorites.length == 4,
      reason: '切回前台没把云端新加的那本并下来',
    );
    expect((await _cloudFavorites()).length, 4, reason: '并集上传,云端那本也还在');

    await tester.pumpWidget(const SizedBox());
  });
}
