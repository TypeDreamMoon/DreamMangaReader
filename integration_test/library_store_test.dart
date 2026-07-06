import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/core/net/image_cache.dart';

/// 验证 ①LibraryStore(收藏/进度/阅读模式)存取 + 落盘往返 ②图片缓存管理器
/// (JsonCacheInfoRepository)能在本平台打开(Windows 无 sqflite,默认配置会崩)。
/// 运行:flutter test integration_test/library_store_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LibraryStore favorites + progress + mode roundtrip',
      (tester) async {
    SharedPreferences.setMockInitialValues({});

    final store = LibraryStore();
    await store.load();
    expect(store.loaded, isTrue);
    expect(store.favorites, isEmpty);
    expect(store.history, isEmpty);
    expect(store.readerMode, ReaderMode.paged);

    store.toggleFavorite(FavoriteEntry(
        sourceId: 'bzm', mangaId: 'x', title: '武煉巔峰', cover: 'c', addedAt: 1));
    expect(store.isFavorite('bzm', 'x'), isTrue);
    expect(store.favorites.length, 1);

    store.markProgress(
        sourceId: 'bzm',
        mangaId: 'x',
        title: '武煉巔峰',
        cover: 'c',
        chapterId: '0_0',
        chapterName: '第1话',
        page: 3,
        total: 10,
        nowMs: 100);
    expect(store.chapterMark('bzm', 'x', '0_0')!.page, 3);
    expect(store.chapterMark('bzm', 'x', '0_0')!.finished, isFalse);
    expect(store.readState('bzm', 'x')!.lastChapterName, '第1话');

    // 读完最后一页 → finished
    store.markProgress(
        sourceId: 'bzm',
        mangaId: 'x',
        title: '武煉巔峰',
        cover: 'c',
        chapterId: '0_1',
        chapterName: '第2话',
        page: 9,
        total: 10,
        nowMs: 200);
    expect(store.chapterMark('bzm', 'x', '0_1')!.finished, isTrue);
    expect(store.history.first.lastChapterId, '0_1'); // 最近读的在前

    store.readerMode = ReaderMode.webtoon;
    expect(store.readerMode, ReaderMode.webtoon);

    // 落盘 + 用新实例重载,验证持久化往返
    store.dispose(); // dispose 会立即刷历史
    final store2 = LibraryStore();
    await store2.load();
    expect(store2.isFavorite('bzm', 'x'), isTrue);
    expect(store2.readState('bzm', 'x')?.chapters['0_0']?.page, 3);
    expect(store2.chapterMark('bzm', 'x', '0_1')?.finished, isTrue);
    expect(store2.readerMode, ReaderMode.webtoon);

    // 取消收藏往返
    store2.toggleFavorite(FavoriteEntry(
        sourceId: 'bzm', mangaId: 'x', title: '武煉巔峰', addedAt: 1));
    expect(store2.isFavorite('bzm', 'x'), isFalse);
    store2.dispose();
  });

  testWidgets('backup export/import roundtrip', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();
    store.toggleFavorite(FavoriteEntry(
        sourceId: 'bzm', mangaId: 'x', title: 'T', addedAt: 1));
    store.markProgress(
        sourceId: 'bzm',
        mangaId: 'x',
        title: 'T',
        chapterId: '0_0',
        chapterName: '第1话',
        page: 3,
        total: 10,
        nowMs: 100);
    store.readerMode = ReaderMode.pagedRtl;
    store.gridColumns = 4;
    final data = store.exportData();

    final store2 = LibraryStore();
    await store2.load();
    await store2.importData(data);
    expect(store2.isFavorite('bzm', 'x'), isTrue);
    expect(store2.readState('bzm', 'x')!.chapters['0_0']!.page, 3);
    expect(store2.readerMode, ReaderMode.pagedRtl);
    expect(store2.gridColumns, 4);
    store.dispose();
    store2.dispose();
  });

  testWidgets('image cache manager opens on this platform', (tester) async {
    // JsonCacheInfoRepository 能打开即通过(sqflite 会在 Windows 抛异常)。
    await clearImageCache();
  });
}
