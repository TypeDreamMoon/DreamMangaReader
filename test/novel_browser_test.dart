import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/source_controller.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/novel_source.dart';
import 'package:dream_manga_reader/core/source/chinese_fold.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/novel/novel_browser.dart';
import 'package:dream_manga_reader/features/library/masonry_feed.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SearchSource implements NovelSource {
  _SearchSource(this.meta, this.result, {this.error});

  final SourceMeta meta;
  final List<Novel> result;
  final Object? error;

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
  Future<Paged<NovelChapter>> getNovelChapters(String novelId, {int? page}) {
    throw UnimplementedError();
  }

  @override
  Future<Paged<Novel>> getNovelDiscovery(int page,
          {Map<String, Object?>? filters}) async =>
      Paged(result);

  @override
  Future<Novel> getNovelDetail(String novelId) {
    throw UnimplementedError();
  }

  @override
  Future<NovelDocument> getNovelDocument(String novelId, String chapterId) {
    throw UnimplementedError();
  }

  @override
  Future<Paged<Novel>> getNovelSearch(String query, int page,
      {Map<String, Object?>? filters}) async {
    if (error != null) throw error!;
    if (meta.id == 'b') {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return Paged(result);
  }

  @override
  Future<Paged<Novel>> getNovelSection(String sectionId, int page) {
    throw UnimplementedError();
  }
}

class _PagedSource implements NovelSource {
  _PagedSource(
    this.meta, {
    required this.firstPage,
    this.secondPage,
    this.error,
  });

  final SourceMeta meta;
  final List<Novel> firstPage;
  final List<Novel>? secondPage;
  final Object? error;
  int calls = 0;

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
  Future<Paged<NovelChapter>> getNovelChapters(String novelId, {int? page}) {
    throw UnimplementedError();
  }

  @override
  Future<Paged<Novel>> getNovelDiscovery(
    int page, {
    Map<String, Object?>? filters,
  }) async {
    calls++;
    if (page == 1) return Paged(firstPage, hasNext: true);
    final next = secondPage;
    if (next != null) return Paged(next, hasNext: true);
    throw error!;
  }

  @override
  Future<Paged<Novel>> getNovelSearch(String query, int page,
          {Map<String, Object?>? filters}) =>
      getNovelDiscovery(page);

  @override
  Future<Novel> getNovelDetail(String novelId) {
    throw UnimplementedError();
  }

  @override
  Future<NovelDocument> getNovelDocument(String novelId, String chapterId) {
    throw UnimplementedError();
  }

  @override
  Future<Paged<Novel>> getNovelSection(String sectionId, int page) {
    throw UnimplementedError();
  }
}

Future<({LibraryStore library, SourceController controller})>
    _pumpBrowserHarness(
  WidgetTester tester, {
  required FeedLayout layout,
  Size size = const Size(390, 844),
}) async {
  await tester.binding.setSurfaceSize(size);
  SharedPreferences.setMockInitialValues({});
  const source = SourceMeta(
    id: 'a',
    name: '来源 A',
    script: '',
    kind: 'novel',
  );
  registeredSources = const [source];
  final library = LibraryStore();
  await library.load();
  library.feedLayout = layout;
  final controller = SourceController(source);
  await controller.load();

  await tester.pumpWidget(MaterialApp(
    // 小说界面走 palette(AppTokens 主题扩展),裸 MaterialApp 取不到。
    theme: buildTheme(AppThemeVariant.light),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: LibraryScope(
      store: library,
      child: SourceScope(
        controller: controller,
        child: Scaffold(
          body: NovelBrowser(
            sourceCatalog: const [source],
            sourceBuilder: (meta) => _SearchSource(
              meta,
              const [
                Novel(
                  id: 'novel-with-a-long-stable-id',
                  title: '这是一部用于验证窄屏排版不会溢出的长篇小说名称',
                  authors: ['测试作者'],
                  description: '这是一段用于验证列表布局最多显示两行且不会挤压其他信息的作品简介。',
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (library: library, controller: controller);
}

void main() {
  for (final layout in FeedLayout.values) {
    testWidgets('novel results use ${layout.name} shared feed layout',
        (tester) async {
      final harness = await _pumpBrowserHarness(tester, layout: layout);
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        registeredSources = [];
        harness.library.dispose();
        harness.controller.dispose();
      });

      final feed = tester.widget<FeedView>(find.byType(FeedView));
      expect(feed.layout, layout);
      expect(find.text('测试作者'), findsWidgets);
      expect(find.text('来源 A'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets('long novel metadata fits at ${size.width}x${size.height}',
        (tester) async {
      final harness = await _pumpBrowserHarness(
        tester,
        layout: FeedLayout.list,
        size: size,
      );
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        registeredSources = [];
        harness.library.dispose();
        harness.controller.dispose();
      });

      expect(find.textContaining('这是一部用于验证'), findsOneWidget);
      expect(find.textContaining('这是一段用于验证'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mixed novel search isolates failures and deduplicates titles',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await ChineseFold.load();
    const sources = [
      SourceMeta(id: 'a', name: '来源 A', script: '', kind: 'novel'),
      SourceMeta(id: 'b', name: '来源 B', script: '', kind: 'novel'),
      SourceMeta(id: 'broken', name: '故障源', script: '', kind: 'novel'),
    ];
    registeredSources = [...sources];
    final library = LibraryStore();
    await library.load();
    final controller = SourceController(sources.first);
    await controller.load();
    final key = GlobalKey<NovelBrowserState>();

    NovelSource build(SourceMeta meta) => switch (meta.id) {
          'a' => _SearchSource(
              meta,
              const [Novel(id: 'a1', title: '诡秘之主')],
            ),
          'b' => _SearchSource(
              meta,
              const [Novel(id: 'b1', title: '詭秘之主')],
            ),
          _ => _SearchSource(meta, const [], error: Exception('timeout')),
        };

    await tester.pumpWidget(MaterialApp(
      // 小说界面走 palette(AppTokens 主题扩展),裸 MaterialApp 取不到。
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: library,
        child: SourceScope(
          controller: controller,
          child: Scaffold(
            body: Column(
              children: [
                TextField(
                  onSubmitted: (query) => key.currentState?.runSearch(query),
                ),
                Expanded(
                  child: NovelBrowser(
                    key: key,
                    sourceBuilder: build,
                    sourceCatalog: sources,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '诡秘');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('诡秘之主'), findsOneWidget);
    expect(find.text('2 个来源'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    library.dispose();
    controller.dispose();
    registeredSources = [];
  });

  testWidgets('a failed extra page stops auto-loading and offers a retry',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    SharedPreferences.setMockInitialValues({});
    const source = SourceMeta(
      id: 'a',
      name: '来源 A',
      script: '',
      kind: 'novel',
    );
    registeredSources = const [source];
    final library = LibraryStore();
    await library.load();
    library.feedLayout = FeedLayout.list;
    library.showSourcePicker = true;
    final controller = SourceController(source);
    await controller.load();
    final paged = _PagedSource(
      source,
      firstPage: [
        for (var index = 0; index < 30; index++)
          Novel(id: 'n$index', title: '小说 $index'),
      ],
      error: Exception('timeout'),
    );

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: library,
        child: SourceScope(
          controller: controller,
          child: Scaffold(
            body: NovelBrowser(
              sourceCatalog: const [source],
              sourceBuilder: (_) => paged,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(paged.calls, 1);

    // 滚到底触发翻页,第二页失败。
    await tester.drag(find.byType(FeedView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(paged.calls, 2);
    expect(find.byKey(const Key('novel-browser-retry-more')), findsOneWidget);
    expect(find.textContaining('timeout'), findsOneWidget);

    // 再怎么滚也不该偷偷重试。
    await tester.drag(find.byType(FeedView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(FeedView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(paged.calls, 2);

    await tester.tap(find.byKey(const Key('novel-browser-retry-more')));
    await tester.pumpAndSettle();
    expect(paged.calls, 3);

    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    library.dispose();
    controller.dispose();
    registeredSources = [];
  });

  testWidgets('a new page is appended instead of reshuffling the whole list',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    SharedPreferences.setMockInitialValues({});
    const source = SourceMeta(
      id: 'a',
      name: '来源 A',
      script: '',
      kind: 'novel',
    );
    registeredSources = const [source];
    final library = LibraryStore();
    await library.load();
    library.feedLayout = FeedLayout.list;
    library.showSourcePicker = true;
    final controller = SourceController(source);
    await controller.load();
    final key = GlobalKey<NovelBrowserState>();
    final paged = _PagedSource(
      source,
      firstPage: [
        for (var index = 0; index < 30; index++)
          Novel(id: 'n$index', title: '小说 $index'),
      ],
      // 第二页是「完全同名」的最高相关度结果:整表重排会把它顶到第一位。
      secondPage: const [Novel(id: 'exact', title: '诡秘之主')],
    );

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: library,
        child: SourceScope(
          controller: controller,
          child: Scaffold(
            body: NovelBrowser(
              key: key,
              sourceCatalog: const [source],
              sourceBuilder: (_) => paged,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    key.currentState!.runSearch('诡秘之主');
    await tester.pumpAndSettle();

    await tester.drag(find.byType(FeedView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(paged.calls, greaterThan(1));
    expect(find.text('诡秘之主'), findsOneWidget);

    await tester.drag(find.byType(FeedView), const Offset(0, 8000));
    await tester.pumpAndSettle();

    expect(find.textContaining('小说 '), findsWidgets);
    expect(find.text('诡秘之主'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    library.dispose();
    controller.dispose();
    registeredSources = [];
  });

  testWidgets('same title by a different author stays a separate book',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await ChineseFold.load();
    const sources = [
      SourceMeta(id: 'a', name: '来源 A', script: '', kind: 'novel'),
      SourceMeta(id: 'b', name: '来源 B', script: '', kind: 'novel'),
    ];
    registeredSources = [...sources];
    final library = LibraryStore();
    await library.load();
    final controller = SourceController(sources.first);
    await controller.load();

    NovelSource build(SourceMeta meta) => switch (meta.id) {
          'a' => _SearchSource(
              meta,
              const [Novel(id: 'a1', title: '长夜', authors: ['甲'])],
            ),
          _ => _SearchSource(
              meta,
              const [Novel(id: 'b1', title: '长夜', authors: ['乙'])],
            ),
        };

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: library,
        child: SourceScope(
          controller: controller,
          child: Scaffold(
            body: NovelBrowser(sourceBuilder: build, sourceCatalog: sources),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('长夜'), findsNWidgets(2));
    expect(find.text('2 个来源'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    library.dispose();
    controller.dispose();
    registeredSources = [];
  });
}
