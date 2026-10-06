import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/local_media_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:dream_manga_reader/core/source/source_repository.dart';
import 'package:dream_manga_reader/core/storage/secret_store.dart';
import 'package:dream_manga_reader/core/sync/sync_controller.dart';
import 'package:dream_manga_reader/core/sync/sync_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late File wallpaper;
  late List<int> wallpaperBytes;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    sandbox = await Directory.systemTemp.createTemp('dmr-sync-weight-');
    // 一张「用户自己的图」:比旧实现的 3MB 上限小,但足够看出是不是被塞进了载荷。
    wallpaperBytes = List<int>.generate(400 * 1024, (i) => i % 251);
    wallpaper = File('${sandbox.path}${Platform.pathSeparator}wall.jpg')
      ..writeAsBytesSync(wallpaperBytes);
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<Map<String, dynamic>> buildUi(LibraryStore lib) async {
    final novels = NovelLibraryStore();
    await novels.load();
    final prefs = await SharedPreferences.getInstance();
    final repo = SourceRepository.forTesting(
      preferences: prefs,
      secrets: _MemorySecretStore(),
      cacheDirectory: sandbox,
    );
    final blob = SyncData.build(
      lib,
      novels,
      repo,
      categories: {SyncCategory.uiSettings},
    );
    novels.dispose();
    return blob;
  }

  test('设了背景图也不把图片塞进同步载荷,只带指纹', () async {
    final lib = LibraryStore();
    await lib.load();
    lib.bgImage = wallpaper.path;

    final blob = await buildUi(lib);
    final blib = (blob['library'] as Map).cast<String, dynamic>();
    final encoded = jsonEncode(blob);

    expect(blib['bgImageHash'], sha256.convert(wallpaperBytes).toString());
    expect(blib['bgImageData'], '', reason: '墓碑要留着,好盖掉云端的旧 base64');
    expect(encoded, isNot(contains(base64Encode(wallpaperBytes.take(64).toList()))));
    expect(encoded.length, lessThan(8 * 1024),
        reason: '界面设置这一类的载荷该是几 KB,不是几 MB');
    lib.dispose();
  });

  test('本机图片路径不出现在载荷里(换台机器也没有这个路径)', () async {
    final lib = LibraryStore();
    await lib.load();
    lib.bgImage = wallpaper.path;

    final blob = await buildUi(lib);
    final blib = (blob['library'] as Map).cast<String, dynamic>();

    expect(blib.containsKey('bgImage'), isFalse);
    expect(jsonEncode(blob), isNot(contains('wall.jpg')));
    lib.dispose();
  });

  test('没设背景图时指纹是空串', () async {
    final lib = LibraryStore();
    await lib.load();

    final blib = ((await buildUi(lib))['library'] as Map).cast<String, dynamic>();
    expect(blib['bgImageHash'], '');
    lib.dispose();
  });

  test('bgImage 不再算「界面与外观」的设置键,换壁纸不触发自动上传', () {
    expect(SyncData.isSettingsKey('bgImage'), isFalse);
    expect(SyncData.isSettingsKey('bgImageHash'), isFalse);
    expect(SyncData.settingsCatOf('bgImage'), isNull);
    // 其余界面设置仍归 uiSettings。
    expect(SyncData.settingsCatOf('bgBlur'), SyncCategory.uiSettings);
  });

  test('对端的路径不会被搬到本机,本机的图原样保留', () async {
    final lib = LibraryStore();
    await lib.load();
    lib.bgImage = wallpaper.path;

    final novels = NovelLibraryStore();
    await novels.load();
    final prefs = await SharedPreferences.getInstance();
    final repo = SourceRepository.forTesting(
      preferences: prefs,
      secrets: _MemorySecretStore(),
      cacheDirectory: sandbox,
    );
    await SyncData.apply(
      {
        'v': 1,
        'library': {
          'v': 1,
          'bgImage': '/from/another/device/other.png',
          'bgImageHash': 'a' * 64,
          'bgBlur': 30.0,
        },
      },
      lib,
      novels,
      repo,
      modes: {SyncCategory.uiSettings: false},
    );

    expect(lib.bgImage, wallpaper.path, reason: '别把对端的路径搬过来');
    expect(lib.bgBlur, 30.0, reason: '其余界面设置照常同步');
    novels.dispose();
    lib.dispose();
  });

  test('自动上传的最小间隔至少 5 分钟', () {
    expect(SyncController.autoUploadMinGap,
        greaterThanOrEqualTo(const Duration(minutes: 5)));
  });

  // 本地数据必须留在设备上:本地播放的进度写在番剧库里(`sourceId = 'local'`、
  // `animeId` = 本地库 id)、本地库索引里是用户的目录名与文件名,两者都不该进
  // 同步载荷 —— 换台设备那些 location 一个都不成立,传上去只会变成悬空条目。
  //
  // 现在番剧库与本地库整体没接进同步层,所以这条断言是通过的;它是**护栏**:
  // 谁把它们接进 `SyncData.build`(或把 `local` 的条目塞进漫画/小说的历史),
  // 这条就会响。设计说明见
  // docs/superpowers/specs/2026-10-07-local-player-reuse-design.md 的「同步」小节。
  test('本地播放记录与本地库索引不进同步载荷', () async {
    final lib = LibraryStore();
    final novels = NovelLibraryStore();
    final anime = AnimeLibraryStore(persistDelay: Duration.zero);
    final root = Directory.systemTemp.createTempSync('dmr-sync-local-');
    final local = LocalMediaStore(rootProvider: () async => root.path);
    addTearDown(() {
      lib.dispose();
      novels.dispose();
      anime.dispose();
      local.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await lib.load();
    await novels.load();
    await anime.load();
    await local.load();
    lib.markProgress(
      sourceId: 'manga-src',
      mangaId: 'm1',
      title: '漫画历史',
      chapterId: 'c1',
      chapterName: '第一话',
      page: 1,
      total: 10,
      nowMs: 1,
    );
    await lib.flushPending();
    anime.saveProgress(
      sourceId: LocalSource.id,
      animeId: 'lib-1',
      title: 'Loki',
      episodeId: 'item-5',
      episodeName: 'E05',
      episodeIndex: 0,
      position: const Duration(minutes: 2),
      duration: const Duration(minutes: 45),
    );
    await anime.flushPending();
    await local.addLibrary(
      name: 'Loki 本地库',
      kind: LocalLibraryKind.folder,
      path: r'C:\Media\私人目录\Loki',
    );

    final prefs = await SharedPreferences.getInstance();
    final repo = SourceRepository.forTesting(
      preferences: prefs,
      secrets: _MemorySecretStore(),
      cacheDirectory: sandbox,
    );
    // 所有类别都勾上:本地那两样不在载荷里,不是因为「没勾这一类」。
    final blob = SyncData.build(
      lib,
      novels,
      repo,
      categories: SyncCategory.values.toSet(),
    );
    final encoded = jsonEncode(blob);

    expect(encoded, contains('漫画历史'), reason: '这份载荷确实在收数据');
    expect(encoded, isNot(contains('Loki')));
    expect(encoded, isNot(contains('item-5')));
    expect(encoded, isNot(contains('lib-1')));
    expect(encoded, isNot(contains('私人目录')));
  });
}
