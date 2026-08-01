import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_download_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/novel_document_cache.dart';
import 'package:dream_manga_reader/core/novel/novel_source.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/novel/novel_detail_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNovelSource implements NovelSource {
  _FakeNovelSource({
    required this.meta,
    required this.novel,
    required this.chapters,
  });

  final SourceMeta meta;
  final Novel novel;
  final List<NovelChapter> chapters;

  @override
  String get id => meta.id;

  @override
  String get name => meta.name;

  @override
  List<FilterDef> get filters => const [];

  @override
  List<SourceSection> get sections => const [];

  @override
  void dispose() {}

  @override
  Future<Paged<NovelChapter>> getNovelChapters(String novelId,
      {int? page}) async {
    return Paged(chapters);
  }

  @override
  Future<Paged<Novel>> getNovelDiscovery(int page,
          {Map<String, Object?>? filters}) async =>
      Paged([novel]);

  @override
  Future<Novel> getNovelDetail(String novelId) async => novel;

  @override
  Future<NovelDocument> getNovelDocument(
    String novelId,
    String chapterId,
  ) async =>
      NovelDocument(
        format: NovelDocumentFormat.html,
        content: '<p>$chapterId</p>',
      );

  @override
  Future<Paged<Novel>> getNovelSearch(String query, int page,
          {Map<String, Object?>? filters}) async =>
      Paged([novel]);

  @override
  Future<Paged<Novel>> getNovelSection(String sectionId, int page) async =>
      Paged([novel]);
}

void main() {
  late Directory temp;
  late LibraryStore library;
  late NovelLibraryStore novelLibrary;
  late NovelDownloadStore downloads;

  const sourceA = SourceMeta(
    id: 'a',
    name: '来源 A',
    script: '',
    kind: 'novel',
  );
  const sourceB = SourceMeta(
    id: 'b',
    name: '来源 B',
    script: '',
    kind: 'novel',
  );
  const novelA = Novel(id: 'na', title: '测试小说');
  const novelB = Novel(id: 'nb', title: '测试小说');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    registeredSources = [sourceA, sourceB];
    temp = await Directory.systemTemp.createTemp('novel-detail-test-');
    library = LibraryStore();
    novelLibrary = NovelLibraryStore();
    downloads = NovelDownloadStore(
      rootProvider: () async => temp.path,
      sourceBuilder: (_) => throw UnimplementedError(),
      cacheFactory: (root) => NovelDocumentCache(root: root, dio: Dio()),
    );
    await Future.wait([
      library.load(),
      novelLibrary.load(),
      downloads.load(),
    ]);
  });

  tearDown(() async {
    library.dispose();
    novelLibrary.dispose();
    downloads.dispose();
    registeredSources = [];
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Widget harness() {
    NovelSource build(SourceMeta meta) => switch (meta.id) {
          'a' => _FakeNovelSource(
              meta: meta,
              novel: novelA,
              chapters: const [
                NovelChapter(id: 'a1', title: 'A1'),
                NovelChapter(id: 'a2', title: 'A2'),
              ],
            ),
          'b' => _FakeNovelSource(
              meta: meta,
              novel: novelB,
              chapters: const [
                NovelChapter(id: 'b1', title: 'B1'),
              ],
            ),
          _ => throw StateError('unknown source'),
        };

    return MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: library,
        child: NovelLibraryScope(
          store: novelLibrary,
          child: NovelDownloadScope(
            store: downloads,
            child: NovelDetailPage(
              meta: sourceA,
              novel: novelA,
              sourceBuilder: build,
              sourceCatalog: const [sourceA, sourceB],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('detail uses one source and never merges chapter lists',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('A1'), findsOneWidget);
    expect(find.text('A2'), findsOneWidget);
    expect(find.text('B1'), findsNothing);
  });

  testWidgets('manual source switch replaces the directory', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('novel-change-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('来源 B'));
    await tester.pumpAndSettle();

    expect(find.text('B1'), findsOneWidget);
    expect(find.text('A1'), findsNothing);
    expect(find.text('A2'), findsNothing);
  });
}
