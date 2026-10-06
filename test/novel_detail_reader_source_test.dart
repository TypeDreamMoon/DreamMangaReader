import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_download_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/novel_document_cache.dart';
import 'package:dream_manga_reader/core/novel/novel_source.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/novel/novel_detail_page.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用完就废:dispose 之后再要正文直接抛,这样「阅读器用了别人的 source」会
/// 在测试里现形,而不是悄悄退化成一次网络失败。
class _DisposableNovelSource implements NovelSource {
  _DisposableNovelSource(this.meta, this.chapters);

  final SourceMeta meta;
  final List<NovelChapter> chapters;
  bool disposed = false;

  @override
  String get id => meta.id;

  @override
  String get name => meta.name;

  @override
  List<FilterDef> get filters => const [];

  @override
  List<SourceSection> get sections => const [];

  @override
  void dispose() => disposed = true;

  @override
  Future<Paged<NovelChapter>> getNovelChapters(
    String novelId, {
    int? page,
  }) async =>
      Paged(chapters);

  @override
  Future<Novel> getNovelDetail(String novelId) async =>
      Novel(id: novelId, title: '测试小说');

  @override
  Future<NovelDocument> getNovelDocument(
    String novelId,
    String chapterId,
  ) async {
    if (disposed) throw StateError('source is disposed');
    return NovelDocument(
      format: NovelDocumentFormat.html,
      content: '<p>正文 $chapterId</p>',
    );
  }

  @override
  Future<Paged<Novel>> getNovelDiscovery(
    int page, {
    Map<String, Object?>? filters,
  }) async =>
      const Paged([]);

  @override
  Future<Paged<Novel>> getNovelSearch(
    String query,
    int page, {
    Map<String, Object?>? filters,
  }) async =>
      const Paged([]);

  @override
  Future<Paged<Novel>> getNovelSection(String sectionId, int page) async =>
      const Paged([]);
}

void main() {
  late Directory temp;
  late LibraryStore library;
  late NovelLibraryStore novelLibrary;
  late NovelDownloadStore downloads;
  late List<_DisposableNovelSource> built;
  late List<SourceMeta> previousSources;

  const meta = SourceMeta(id: 'a', name: '来源 A', script: '', kind: 'novel');
  const novel = Novel(id: 'na', title: '测试小说');
  const chapters = [
    NovelChapter(id: 'a1', title: 'A1'),
    NovelChapter(id: 'a2', title: 'A2'),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    previousSources = registeredSources;
    registeredSources = const [meta];
    built = [];
    temp = await Directory.systemTemp.createTemp('novel-reader-source-test-');
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
    registeredSources = previousSources;
    library.dispose();
    novelLibrary.dispose();
    downloads.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  // Scope 挂在 MaterialApp 之上:阅读器是推上去的另一条路由,挂在 home 里的
  // scope 它够不着。
  Widget harness({Key? detailKey}) {
    return LibraryScope(
      store: library,
      child: NovelLibraryScope(
        store: novelLibrary,
        child: NovelDownloadScope(
          store: downloads,
          child: MaterialApp(
            theme: buildTheme(AppThemeVariant.light),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: NovelDetailPage(
              key: detailKey,
              meta: meta,
              novel: novel,
              sourceBuilder: (source) {
                final built0 = _DisposableNovelSource(source, chapters);
                built.add(built0);
                return built0;
              },
              sourceCatalog: const [meta],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('an open reader keeps reading after the detail page lets go',
      (tester) async {
    await tester.pumpWidget(harness(detailKey: const ValueKey('first')));
    await tester.pumpAndSettle();
    expect(built, hasLength(1));

    await tester.tap(find.text('A1'));
    await tester.pumpAndSettle();
    final reader = tester.widget<NovelReaderPage>(find.byType(NovelReaderPage));

    // 详情页在阅读器还开着的时候放掉自己的 source(换源 / 页面被收掉都走这里)。
    await tester.pumpWidget(harness(detailKey: const ValueKey('second')));
    await tester.pumpAndSettle();
    expect(built.first.disposed, isTrue);

    // 翻下一章照样翻得动 —— 阅读器手里那份没被牵连。
    final document = await reader.loadDocument(chapters[1]);
    expect(document.content, contains('a2'));
  });

  testWidgets('closing the reader releases the source it was given',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('A1'));
    await tester.pumpAndSettle();
    expect(built, hasLength(2));
    expect(built[1].disposed, isFalse);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    expect(built[1].disposed, isTrue);
  });
}
