import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/features/library/history_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('history mixes all content and dispatches delete and clear',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final manga = LibraryStore();
    final novel = NovelLibraryStore();
    final anime = AnimeLibraryStore(persistDelay: Duration.zero);
    await manga.load();
    await novel.load();
    await anime.load();
    addTearDown(manga.dispose);
    addTearDown(novel.dispose);
    addTearDown(anime.dispose);

    manga.markProgress(
      sourceId: 'manga-source',
      mangaId: 'manga-1',
      title: '漫画历史',
      chapterId: 'ch-1',
      chapterName: '第一话',
      page: 2,
      total: 10,
      nowMs: 10,
    );
    final novelEntry = NovelLibraryEntry.remote(
      sourceId: 'novel-source',
      novelId: 'novel-1',
      title: '小说历史',
    );
    novel.toggleRemoteFavorite(novelEntry);
    novel.saveProgress(
      novelEntry.key,
      const NovelLocator(chapterId: '第二章'),
      updatedAt: 20,
    );
    anime.saveProgress(
      sourceId: 'anime-source',
      animeId: 'anime-1',
      title: '番剧历史',
      episodeId: 'ep-3',
      episodeName: '第三集',
      episodeIndex: 2,
      position: const Duration(minutes: 12, seconds: 34),
      duration: const Duration(minutes: 24),
      updatedAt: 30,
    );
    await manga.flushPending();
    await novel.flushPending();
    await anime.flushPending();

    await tester.pumpWidget(MaterialApp(
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
            child: const HistoryPage(),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.byType(SegmentedButton), findsNothing);
    expect(find.textContaining('12:34'), findsOneWidget);
    final animeY =
        tester.getTopLeft(find.byKey(const Key('history-row-anime'))).dy;
    final novelY =
        tester.getTopLeft(find.byKey(const Key('history-row-novel'))).dy;
    final mangaY =
        tester.getTopLeft(find.byKey(const Key('history-row-manga'))).dy;
    expect(animeY, lessThan(novelY));
    expect(novelY, lessThan(mangaY));

    await tester.tap(find.byKey(const Key('history-remove-anime')));
    await tester.pump();
    expect(anime.history, isEmpty);
    expect(novel.history, isNotEmpty);
    expect(manga.history, isNotEmpty);

    await tester.tap(find.byKey(const Key('history-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空').last);
    await tester.pumpAndSettle();

    expect(manga.history, isEmpty);
    expect(novel.history, isEmpty);
    expect(anime.history, isEmpty);
  });
}
