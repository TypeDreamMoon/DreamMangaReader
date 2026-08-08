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
import 'package:dream_manga_reader/app/theme/app_theme.dart';
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
  late Novel detailedNovelA;
  late List<NovelChapter> chaptersA;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    registeredSources = [sourceA, sourceB];
    detailedNovelA = novelA;
    chaptersA = const [
      NovelChapter(id: 'a1', title: 'A1'),
      NovelChapter(id: 'a2', title: 'A2'),
    ];
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

  Widget harness({Object? heroTag}) {
    NovelSource build(SourceMeta meta) => switch (meta.id) {
          'a' => _FakeNovelSource(
              meta: meta,
              novel: detailedNovelA,
              chapters: chaptersA,
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
      // 小说界面走 palette(AppTokens 主题扩展),裸 MaterialApp 取不到。
      theme: buildTheme(AppThemeVariant.light),
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
              heroTag: heroTag,
              sourceBuilder: build,
              sourceCatalog: const [sourceA, sourceB],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the hero tag lands on the detail cover', (tester) async {
    // 列表页把 tag 交给详情页,封面才能从卡片飞过来。同屏只能有这一个 Hero,
    // 多一个就是 tag 撞车(Flutter 会直接抛)。
    await tester.pumpWidget(harness(heroTag: 'nfeed:a:novel-a:0'));
    await tester.pumpAndSettle();

    final heroes = tester.widgetList<Hero>(find.byType(Hero)).toList();
    expect(heroes, hasLength(1));
    expect(heroes.single.tag, 'nfeed:a:novel-a:0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no hero tag means no hero on the detail cover', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byType(Hero), findsNothing);
  });

  testWidgets('detail uses one source and never merges chapter lists',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('A1'), findsOneWidget);
    expect(find.text('A2'), findsOneWidget);
    expect(find.text('B1'), findsNothing);
  });

  testWidgets('opening an unfavorited remote novel keeps it in history',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('A1'));

    final entry = novelLibrary.entryFor('remote:a:na');
    expect(entry, isNotNull);
    expect(entry?.title, '测试小说');
    expect(entry?.favorite, isFalse);
  });

  testWidgets('novel detail uses manga-style wide split layout',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('novel-detail-hero')), findsOneWidget);
    expect(find.byKey(const Key('novel-detail-wide')), findsOneWidget);
    expect(find.byKey(const Key('novel-detail-directory')), findsOneWidget);
    expect(find.text('A1'), findsOneWidget);
  });

  testWidgets('novel detail uses manga-style narrow layout', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('novel-detail-hero')), findsOneWidget);
    expect(find.byKey(const Key('novel-detail-narrow')), findsOneWidget);
    expect(find.byKey(const Key('novel-detail-directory')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved chapter is highlighted in the lazy directory',
      (tester) async {
    novelLibrary.saveProgress(
      NovelIdentity.remote(sourceA.id, novelA.id).key,
      const NovelLocator(chapterId: 'a2', fraction: .4),
    );
    await novelLibrary.flushPending();
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final active = find.byKey(const Key('novel-chapter-active'));
    expect(active, findsOneWidget);
    expect(
      find.descendant(of: active, matching: find.text('A2')),
      findsOneWidget,
    );
  });

  testWidgets('long directory initially reveals the saved chapter',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    chaptersA = List.generate(
      600,
      (index) => NovelChapter(id: 'a$index', title: '章节 $index'),
    );
    novelLibrary.saveProgress(
      NovelIdentity.remote(sourceA.id, novelA.id).key,
      const NovelLocator(chapterId: 'a480', fraction: .4),
    );
    await novelLibrary.flushPending();

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final active = find.byKey(const Key('novel-chapter-active'));
    expect(active, findsOneWidget);
    expect(
      find.descendant(of: active, matching: find.text('章节 480')),
      findsOneWidget,
    );
  });

  testWidgets('long description can expand and collapse', (tester) async {
    detailedNovelA = Novel(
      id: 'na',
      title: '测试小说',
      description: List.filled(30, '这是一段用于验证展开与收起行为的很长简介。').join(),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final description = find.byKey(const Key('novel-detail-description'));
    expect(description, findsOneWidget);
    expect(tester.widget<Text>(description).maxLines, 10);
    expect(find.text('展开全部'), findsOneWidget);

    await tester.tap(find.text('展开全部'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(description).maxLines, isNull);
    expect(find.text('收起'), findsOneWidget);
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
