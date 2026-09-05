import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/features/library/shelf_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late LibraryStore manga;
  late NovelLibraryStore novel;
  late AnimeLibraryStore anime;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    manga = LibraryStore();
    novel = NovelLibraryStore();
    anime = AnimeLibraryStore(persistDelay: Duration.zero);
    await manga.load();
    await novel.load();
    await anime.load();
  });

  tearDown(() {
    manga.dispose();
    novel.dispose();
    anime.dispose();
  });

  List<ShelfItem> project({ShelfKind? kind, String query = ''}) =>
      ShelfProjector.build(
        manga: manga,
        novel: novel,
        anime: anime,
        kind: kind,
        query: query,
      );

  test('三类收藏混排成一条,按收藏时间倒序', () {
    manga.toggleFavorite(FavoriteEntry(
      sourceId: 'm',
      mangaId: '1',
      title: '漫画甲',
      addedAt: 100,
    ));
    anime.toggleFavorite(const AnimeFavoriteEntry(
      sourceId: 'a',
      animeId: '1',
      title: '番剧甲',
      addedAt: 300,
    ));
    // 远端小说收藏时 store 会把 addedAt 盖成当前时间(epoch ms),必然排在上面两条之前。
    novel.toggleRemoteFavorite(NovelLibraryEntry.remote(
      sourceId: 'n',
      novelId: '1',
      title: '小说甲',
    ));

    final items = project();
    expect(items.map((e) => e.kind).toList(),
        [ShelfKind.novel, ShelfKind.anime, ShelfKind.manga]);
    expect(items.map((e) => e.title).toList(), ['小说甲', '番剧甲', '漫画甲']);
  });

  test('同一部漫画的多源收藏合成一条,带源数角标', () {
    manga.toggleFavorite(FavoriteEntry(
      sourceId: 'src-a',
      mangaId: '1',
      title: '绝世武神',
      addedAt: 100,
    ));
    manga.toggleFavorite(FavoriteEntry(
      sourceId: 'src-b',
      mangaId: '2',
      title: '絕世武神', // 繁体同名:与上一条是同一部书
      addedAt: 200,
    ));

    final items = project();
    expect(items, hasLength(1));
    expect(items.single.sourceCount, 2);
  });

  test('按类型筛选只出该类', () {
    manga.toggleFavorite(FavoriteEntry(
      sourceId: 'm',
      mangaId: '1',
      title: '漫画甲',
      addedAt: 100,
    ));
    anime.toggleFavorite(const AnimeFavoriteEntry(
      sourceId: 'a',
      animeId: '1',
      title: '番剧甲',
      addedAt: 300,
    ));

    expect(project(kind: ShelfKind.anime).map((e) => e.title), ['番剧甲']);
    expect(project(kind: ShelfKind.manga).map((e) => e.title), ['漫画甲']);
    expect(project(kind: ShelfKind.novel), isEmpty);
  });

  test('搜索同时匹配标题与小说作者', () {
    manga.toggleFavorite(FavoriteEntry(
      sourceId: 'm',
      mangaId: '1',
      title: '深海奇谭',
      addedAt: 100,
    ));
    novel.toggleRemoteFavorite(NovelLibraryEntry.remote(
      sourceId: 'n',
      novelId: '1',
      title: '山月记',
      authors: const ['中岛敦'],
    ));

    expect(project(query: '深海').map((e) => e.title), ['深海奇谭']);
    expect(project(query: '中岛敦').map((e) => e.title), ['山月记']);
    expect(project(query: '查无此书'), isEmpty);
  });

  test('未收藏的小说(仅有历史)不进收藏区', () {
    final entry = NovelLibraryEntry.remote(
      sourceId: 'n',
      novelId: '1',
      title: '只读过',
    );
    novel.toggleRemoteFavorite(entry); // 收藏
    novel.saveProgress(entry.key, const NovelLocator(chapterId: '第一章'));
    novel.toggleRemoteFavorite(entry); // 取消收藏(有历史 → 条目保留)

    expect(novel.entryFor(entry.key), isNotNull);
    expect(project(), isEmpty);
  });

  group('作品分组索引', () {
    test('繁简/装饰副标题仍归成一张卡,并累加源数', () {
      var at = 100;
      for (final (src, title) in [
        ('a', '雾山五行'),
        ('b', '霧山五行'),
        ('c', '[连载]雾山五行'),
      ]) {
        manga.toggleFavorite(FavoriteEntry(
          sourceId: src,
          mangaId: '1',
          title: title,
          addedAt: at++,
        ));
      }

      final items = project();
      expect(items, hasLength(1), reason: '同一部书不该出三张卡');
      expect(items.single.sourceCount, 3);
    });

    test('加了后缀的续作不会被并进本篇', () {
      manga.toggleFavorite(FavoriteEntry(
        sourceId: 'a',
        mangaId: '1',
        title: '雾山五行',
        addedAt: 100,
      ));
      manga.toggleFavorite(FavoriteEntry(
        sourceId: 'a',
        mangaId: '2',
        title: '雾山五行外传',
        addedAt: 101,
      ));

      expect(project(), hasLength(2));
    });

    test('分组不再拿每个标题跟全表比一遍', () {
      // realistic 形状:300 部不同的书,标题等长、每 10 部共用一个常见字
      // (同长 + 共字才可能是同作,是索引唯一需要真比一次的情况)。
      const n = 300;
      for (var i = 0; i < n; i++) {
        final shared = String.fromCharCode(0x9000 + i % 30);
        final rest = String.fromCharCodes([
          0x4E00 + i * 3,
          0x4E00 + i * 3 + 1,
          0x4E00 + i * 3 + 2,
        ]);
        manga.toggleFavorite(FavoriteEntry(
          sourceId: 's$i',
          mangaId: '$i',
          title: '$shared$rest',
          addedAt: i,
        ));
      }

      ShelfProjector.debugWorkKeyComparisons = 0;
      final items = project();

      expect(items, hasLength(n), reason: '共用一个字不等于同一部作品');
      // 旧实现每个标题都跟已有的全部 key 比一遍 ≈ n²/2 ≈ 45000 次。
      expect(ShelfProjector.debugWorkKeyComparisons, lessThan(3000),
          reason: '只该跟同长且共字的那几个比');
    });
  });
}
