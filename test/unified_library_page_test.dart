import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/app/source_controller.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/features/library/library_page.dart';
import 'package:dream_manga_reader/features/library/recommend_controller.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('library orders unified history before three favorite sections',
      (tester) async {
    final fixture = await _LibraryFixture.create();
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1200, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(
      LibraryPage(recommendController: fixture.recommendations),
    ));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(SegmentedButton), findsNothing);
    final titles = ['历史记录', '漫画收藏', '小说收藏', '番剧收藏'];
    final positions = [
      for (final title in titles) tester.getTopLeft(find.text(title)).dy,
    ];
    expect(positions, orderedEquals([...positions]..sort()));
  });

  testWidgets('one search filters manga novel and anime favorites',
      (tester) async {
    final fixture = await _LibraryFixture.create();
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(
      LibraryPage(recommendController: fixture.recommendations),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '共同');
    await tester.pump();

    expect(find.text('共同漫画'), findsWidgets);
    expect(find.text('共同小说'), findsWidgets);
    expect(find.text('共同番剧'), findsWidgets);
    expect(find.text('历史漫画'), findsNothing);
    expect(find.text('历史小说'), findsNothing);
    expect(find.text('历史番剧'), findsNothing);
  });
}

class _LibraryFixture {
  _LibraryFixture({
    required this.manga,
    required this.novel,
    required this.anime,
    required this.sources,
    required this.recommendations,
  });

  final LibraryStore manga;
  final NovelLibraryStore novel;
  final AnimeLibraryStore anime;
  final SourceController sources;
  final _NoopRecommendController recommendations;

  static Future<_LibraryFixture> create() async {
    SharedPreferences.setMockInitialValues(const {});
    final manga = LibraryStore();
    final novel = NovelLibraryStore();
    final anime = AnimeLibraryStore(persistDelay: Duration.zero);
    final sources = SourceController();
    final recommendations = _NoopRecommendController();
    await manga.load();
    await novel.load();
    await anime.load();
    manga.toggleFavorite(FavoriteEntry(
      sourceId: 'manga-source',
      mangaId: 'manga-favorite',
      title: '共同漫画',
      addedAt: 10,
    ));
    manga.markProgress(
      sourceId: 'manga-source',
      mangaId: 'manga-history',
      title: '历史漫画',
      chapterId: 'ch-1',
      chapterName: '第一话',
      page: 1,
      total: 10,
      nowMs: 10,
    );
    final favoriteNovel = NovelLibraryEntry.remote(
      sourceId: 'novel-source',
      novelId: 'novel-favorite',
      title: '共同小说',
      addedAt: 20,
    );
    novel.toggleRemoteFavorite(favoriteNovel);
    final historyNovel = NovelLibraryEntry.remote(
      sourceId: 'novel-source',
      novelId: 'novel-history',
      title: '历史小说',
      addedAt: 5,
    );
    novel.toggleRemoteFavorite(historyNovel);
    novel.saveProgress(
      historyNovel.key,
      const NovelLocator(chapterId: '第二章'),
      updatedAt: 20,
    );
    novel.toggleRemoteFavorite(historyNovel);
    anime.toggleFavorite(const AnimeFavoriteEntry(
      sourceId: 'anime-source',
      animeId: 'anime-favorite',
      title: '共同番剧',
      addedAt: 30,
    ));
    anime.saveProgress(
      sourceId: 'anime-source',
      animeId: 'anime-history',
      title: '历史番剧',
      episodeId: 'ep-1',
      episodeName: '第一集',
      episodeIndex: 0,
      position: const Duration(seconds: 12),
      duration: const Duration(minutes: 24),
      updatedAt: 30,
    );
    await manga.flushPending();
    await novel.flushPending();
    await anime.flushPending();
    return _LibraryFixture(
      manga: manga,
      novel: novel,
      anime: anime,
      sources: sources,
      recommendations: recommendations,
    );
  }

  Widget host(Widget child) => MaterialApp(
        theme: buildTheme(AppThemeVariant.light),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: LibraryScope(
          store: manga,
          child: NovelLibraryScope(
            store: novel,
            child: AnimeLibraryScope(
              store: anime,
              child: SourceScope(controller: sources, child: child),
            ),
          ),
        ),
      );

  void dispose() {
    manga.dispose();
    novel.dispose();
    anime.dispose();
    sources.dispose();
    recommendations.dispose();
  }
}

class _NoopRecommendController extends RecommendController {
  @override
  Future<void> ensure(LibraryStore store, {bool force = false}) async {}
}
