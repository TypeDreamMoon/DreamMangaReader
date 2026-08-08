import 'dart:async';
import 'dart:io';

import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_search_index.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_search_sheet.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('search sheet selects full-book scope and opens a result',
      (tester) async {
    final index = _FakeSearchIndex();
    NovelSearchResult? selected;
    await tester.pumpWidget(_app(
      NovelReaderSearchSheet(
        index: index,
        bookKey: 'remote:s:n1',
        sourceFingerprint: 'v1',
        chapters: const [NovelChapter(id: 'c1', title: '第一章')],
        loadCachedDocument: (_) async => null,
        fetchDocument: (_) async => _document('正文'),
        onResultSelected: (result) => selected = result,
      ),
    ));

    await tester.enterText(
      find.byKey(const Key('novel-search-query')),
      '目标',
    );
    await tester.tap(find.byKey(const Key('novel-search-scope-full')));
    await tester.tap(find.byKey(const Key('novel-search-submit')));
    await tester.pumpAndSettle();

    expect(index.lastFetchMissing, isTrue);
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('前文目标后文'), findsOneWidget);
    await tester.tap(find.text('前文目标后文'));
    expect(selected?.chapterId, 'c1');
  });

  testWidgets('active search exposes progress and acknowledges cancellation',
      (tester) async {
    final index = _FakeSearchIndex(waitForCancellation: true);
    await tester.pumpWidget(_app(
      NovelReaderSearchSheet(
        index: index,
        bookKey: 'remote:s:n1',
        sourceFingerprint: 'v1',
        chapters: const [NovelChapter(id: 'c1', title: '第一章')],
        loadCachedDocument: (_) async => null,
        onResultSelected: (_) {},
      ),
    ));
    await tester.enterText(
      find.byKey(const Key('novel-search-query')),
      '目标',
    );
    await tester.tap(find.byKey(const Key('novel-search-submit')));
    await tester.pump();

    expect(find.byKey(const Key('novel-search-progress')), findsOneWidget);
    await tester.tap(find.byKey(const Key('novel-search-cancel')));
    await tester.pumpAndSettle();

    expect(index.wasCancelled, isTrue);
    expect(find.text('已取消'), findsOneWidget);
  });

  testWidgets('search controls and completion states are localized',
      (tester) async {
    final index = _FakeSearchIndex(empty: true);
    await tester.pumpWidget(_app(
      NovelReaderSearchSheet(
        index: index,
        bookKey: 'remote:s:n1',
        sourceFingerprint: 'v1',
        chapters: const [NovelChapter(id: 'c1', title: 'Chapter 1')],
        loadCachedDocument: (_) async => null,
        onResultSelected: (_) {},
      ),
      locale: const Locale('en'),
    ));

    expect(find.text('Cached'), findsOneWidget);
    expect(find.text('Full book'), findsOneWidget);
    expect(find.byTooltip('Search'), findsOneWidget);
    expect(find.byKey(const Key('novel-search-query')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('novel-search-query')), 'none');
    await tester.tap(find.byKey(const Key('novel-search-submit')));
    await tester.pumpAndSettle();
    expect(find.text('No results found'), findsOneWidget);
  });
}

Widget _app(Widget home, {Locale locale = const Locale('zh')}) => MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: home),
    );

NovelDocument _document(String value) => NovelDocument(
      format: NovelDocumentFormat.text,
      content: value,
    );

class _FakeSearchIndex extends NovelSearchIndex {
  _FakeSearchIndex({this.waitForCancellation = false, this.empty = false})
      : super(rootDirectory: () async => Directory.systemTemp);

  final bool waitForCancellation;
  final bool empty;
  bool? lastFetchMissing;
  bool wasCancelled = false;

  @override
  Stream<NovelSearchEvent> search({
    required String bookKey,
    required String sourceFingerprint,
    required List<NovelChapter> chapters,
    required String query,
    required NovelSearchDocumentLoader loadCachedDocument,
    NovelSearchDocumentFetcher? fetchDocument,
    bool fetchMissing = false,
    NovelSearchCancellationToken? cancellation,
  }) async* {
    lastFetchMissing = fetchMissing;
    yield const NovelSearchProgress(
      processedChapters: 1,
      totalChapters: 2,
      fetchedChapters: 0,
    );
    if (waitForCancellation) {
      while (!(cancellation?.isCancelled ?? false)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      wasCancelled = true;
      yield const NovelSearchCancelled();
      return;
    }
    if (empty) {
      yield const NovelSearchCompleted(resultCount: 0);
      return;
    }
    yield NovelSearchResultBatch([
      const NovelSearchResult(
        chapterId: 'c1',
        chapterTitle: '第一章',
        chapterIndex: 0,
        snippet: '前文目标后文',
        locator: NovelLocator(chapterId: 'c1', quote: '目标'),
      ),
    ]);
    yield const NovelSearchCompleted(resultCount: 1);
  }
}
