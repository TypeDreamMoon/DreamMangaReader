// The fake accepts these controls for follow-up mixed-source scenarios.
// ignore_for_file: unused_element_parameter

import 'dart:async';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/source_controller.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/source/chinese_fold.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/anime/anime_browser.dart';
import 'package:dream_manga_reader/features/anime/anime_detail_page.dart';
import 'package:dream_manga_reader/features/common/source_picker.dart';
import 'package:dream_manga_reader/features/library/manga_cover.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAnimeSource implements MangaSource {
  _FakeAnimeSource(
    this.meta, {
    this.discoveryResult = const Paged<Manga>([]),
    this.searchResult = const Paged<Manga>([]),
    this.error,
    this.gate,
    this.discoveryHandler,
    this.searchHandler,
  });

  final SourceMeta meta;
  final Paged<Manga> discoveryResult;
  final Paged<Manga> searchResult;
  final Object? error;
  final Future<void>? gate;
  final Future<Paged<Manga>> Function(int page)? discoveryHandler;
  final Future<Paged<Manga>> Function(String query, int page)? searchHandler;
  int discoveryCalls = 0;
  int searchCalls = 0;
  final List<int> discoveryPages = [];
  bool disposed = false;

  @override
  String get id => meta.id;

  @override
  String get name => meta.name;

  @override
  String get lang => 'zh';

  @override
  String get baseUrl => 'https://${meta.id}.example';

  @override
  int get version => 1;

  @override
  bool get nsfw => false;

  @override
  List<FilterDef> get filters => const [];

  @override
  List<SourceSection> get sections => const [];

  @override
  Future<Paged<Manga>> getDiscovery(int page,
      {Map<String, Object?>? filters}) async {
    discoveryCalls++;
    discoveryPages.add(page);
    await gate;
    if (error != null) throw error!;
    return discoveryHandler?.call(page) ?? discoveryResult;
  }

  @override
  Future<Paged<Manga>> getSearch(String query, int page,
      {Map<String, Object?>? filters}) async {
    searchCalls++;
    await gate;
    if (error != null) throw error!;
    return searchHandler?.call(query, page) ?? searchResult;
  }

  @override
  Future<Paged<Manga>> getSection(String sectionId, int page) =>
      throw UnimplementedError();

  @override
  Future<Manga> getMangaDetail(String mangaId) => throw UnimplementedError();

  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) =>
      throw UnimplementedError();

  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) =>
      throw UnimplementedError();

  @override
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) =>
      throw UnimplementedError();

  @override
  Future<SourceLogin> login(String username, String password) =>
      throw UnimplementedError();

  @override
  void dispose() {
    disposed = true;
  }
}

const _sources = [
  SourceMeta(id: 'anime-a', name: '番剧 A', script: '', kind: 'anime'),
  SourceMeta(id: 'anime-b', name: '番剧 B', script: '', kind: 'anime'),
];

class _RecordingNavigatorObserver extends NavigatorObserver {
  Route<dynamic>? pushedRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (previousRoute != null) pushedRoute = route;
  }
}

Future<({LibraryStore library, SourceController controller})> _pumpBrowser(
  WidgetTester tester, {
  required bool showSourcePicker,
  required Map<String, List<_FakeAnimeSource>> instances,
  List<SourceMeta> sources = _sources,
  String? savedSourceId,
  _FakeAnimeSource Function(SourceMeta meta, int buildIndex)? sourceFactory,
  NavigatorObserver? navigatorObserver,
  AnimeSearchVariants? searchVariants,
  bool settle = true,
}) async {
  SharedPreferences.setMockInitialValues({
    if (savedSourceId != null) 'source.current.anime': savedSourceId,
  });
  registeredSources = [...sources];
  final library = LibraryStore();
  await library.load();
  library.showSourcePicker = showSourcePicker;
  final controller = SourceController(sources.first);
  await controller.load();

  MangaSource build(SourceMeta meta) {
    final current = instances[meta.id] ?? const <_FakeAnimeSource>[];
    final instance =
        sourceFactory?.call(meta, current.length) ?? _FakeAnimeSource(meta);
    instances.putIfAbsent(meta.id, () => []).add(instance);
    return instance;
  }

  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(AppThemeVariant.light),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    navigatorObservers: [if (navigatorObserver != null) navigatorObserver],
    home: LibraryScope(
      store: library,
      child: SourceScope(
        controller: controller,
        child: Scaffold(
          body: AnimeBrowser(
            sourceBuilder: build,
            sourceCatalog: sources,
            searchVariants: searchVariants,
          ),
        ),
      ),
    ),
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return (library: library, controller: controller);
}

void main() {
  tearDown(() {
    registeredSources = [];
  });

  testWidgets(
      'hides source picker and loads every enabled anime source in mixed mode',
      (tester) async {
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: instances,
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });

    expect(find.byType(SourcePickerPill), findsNothing);
    expect(instances['anime-a'], hasLength(1));
    expect(instances['anime-b'], hasLength(1));
    expect(instances['anime-a']!.single.discoveryCalls, 1);
    expect(instances['anime-b']!.single.discoveryCalls, 1);
  });

  testWidgets('visible picker restores the saved anime source', (tester) async {
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: true,
      instances: instances,
      savedSourceId: 'anime-b',
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });

    expect(find.byType(SourcePickerPill), findsOneWidget);
    expect(instances['anime-a'], isNull);
    expect(instances['anime-b'], hasLength(1));
    expect(instances['anime-b']!.single.discoveryCalls, 1);
  });

  testWidgets(
      'rebuilds active sources when an enabled anime source is disabled',
      (tester) async {
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: instances,
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });
    final originalA = instances['anime-a']!.single;
    final originalB = instances['anime-b']!.single;

    harness.library.setSourceEnabled('anime-b', false, 2);
    await tester.pumpAndSettle();

    expect(originalA.disposed, isTrue);
    expect(originalB.disposed, isTrue);
    expect(instances['anime-a'], hasLength(2));
    expect(instances['anime-b'], hasLength(1));
    expect(instances['anime-a']!.last.discoveryCalls, 1);
  });

  testWidgets(
      'rebuild starts discovery when prior mixed requests are still pending',
      (tester) async {
    final instances = <String, List<_FakeAnimeSource>>{};
    final oldGate = Completer<void>();
    addTearDown(() {
      if (!oldGate.isCompleted) oldGate.complete();
    });
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: instances,
      sourceFactory: (meta, buildIndex) => _FakeAnimeSource(
        meta,
        gate: buildIndex == 0 ? oldGate.future : null,
        discoveryResult: Paged([
          Manga(
            id: buildIndex == 0 ? 'old-${meta.id}' : 'new-${meta.id}',
            title: buildIndex == 0 ? '旧结果' : '新结果',
          ),
        ]),
      ),
      settle: false,
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });

    expect(instances['anime-a']!.single.discoveryCalls, 1);
    expect(instances['anime-b']!.single.discoveryCalls, 1);

    harness.library.setSourceEnabled('anime-b', false, 2);
    await tester.pump();
    await tester.pump();

    expect(instances['anime-a'], hasLength(2));
    expect(instances['anime-a']!.last.discoveryCalls, 1);
    expect(find.text('新结果'), findsOneWidget);

    oldGate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('旧结果'), findsNothing);
    expect(find.text('新结果'), findsOneWidget);
  });

  testWidgets('mixed anime isolates failures and deduplicates titles',
      (tester) async {
    await ChineseFold.load();
    const broken = SourceMeta(
      id: 'anime-broken',
      name: '故障源',
      script: '',
      kind: 'anime',
    );
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: instances,
      sources: const [..._sources, broken],
      sourceFactory: (meta, _) => switch (meta.id) {
        'anime-a' => _FakeAnimeSource(
            meta,
            discoveryResult: const Paged([
              Manga(id: 'a-1', title: '刀剑神域'),
            ]),
          ),
        'anime-b' => _FakeAnimeSource(
            meta,
            discoveryResult: const Paged([
              Manga(id: 'b-1', title: '刀劍神域'),
            ]),
          ),
        _ => _FakeAnimeSource(meta, error: StateError('timeout')),
      },
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });

    expect(find.text('刀剑神域'), findsOneWidget);
    expect(find.text('刀劍神域'), findsNothing);
    expect(find.text('2源'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
  });

  testWidgets('all failed anime sources expose retry', (tester) async {
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: instances,
      sourceFactory: (meta, _) =>
          _FakeAnimeSource(meta, error: Exception(meta.id)),
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });

    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('a slow anime source does not block a fast source next page',
      (tester) async {
    final slowGate = Completer<void>();
    addTearDown(() {
      if (!slowGate.isCompleted) slowGate.complete();
    });
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: instances,
      settle: false,
      sourceFactory: (meta, _) {
        if (meta.id == 'anime-b') {
          return _FakeAnimeSource(meta, gate: slowGate.future);
        }
        return _FakeAnimeSource(
          meta,
          discoveryHandler: (page) async => page == 1
              ? Paged(
                  List.generate(
                    30,
                    (index) => Manga(
                      id: 'a-$index',
                      title: '快速番剧 $index',
                    ),
                  ),
                  hasNext: true,
                )
              : const Paged([]),
        );
      },
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });
    await tester.pump();

    expect(find.text('快速番剧 0'), findsOneWidget);
    await tester.fling(
      find.byType(GridView),
      const Offset(0, -2400),
      1200,
    );
    await tester.pump();

    expect(instances['anime-a']!.single.discoveryPages, [1, 2]);
    expect(instances['anime-b']!.single.discoveryPages, [1]);
    slowGate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('anime picker persists a selected source', (tester) async {
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: true,
      instances: instances,
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });
    final oldA = instances['anime-a']!.single;

    await tester.tap(find.byType(SourcePickerPill));
    await tester.pumpAndSettle();
    await tester.tap(find.text('番剧 B').last);
    await tester.pumpAndSettle();

    expect(harness.controller.currentFor('anime')?.id, 'anime-b');
    expect(find.textContaining('番剧 B'), findsOneWidget);
    expect(oldA.disposed, isTrue);
    expect(instances['anime-b']!.single.discoveryCalls, 1);
  });

  testWidgets('mixed anime card opens detail with its representative source',
      (tester) async {
    final instances = <String, List<_FakeAnimeSource>>{};
    final observer = _RecordingNavigatorObserver();
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: instances,
      navigatorObserver: observer,
      sourceFactory: (meta, _) => _FakeAnimeSource(
        meta,
        discoveryResult: meta.id == 'anime-b'
            ? const Paged([Manga(id: 'b-show', title: '代表番剧')])
            : const Paged([]),
      ),
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });

    await tester.tap(find.byType(MangaCover));
    final route = observer.pushedRoute! as PageRouteBuilder<dynamic>;
    final detail = route.pageBuilder(
      tester.element(find.byType(AnimeBrowser)),
      const AlwaysStoppedAnimation(1),
      const AlwaysStoppedAnimation(0),
    ) as AnimeDetailPage;
    expect(detail.meta.id, 'anime-b');
    expect(detail.anime.id, 'b-show');
  });

  testWidgets('manual mixed mode survives unrelated library notifications',
      (tester) async {
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: true,
      instances: instances,
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });

    await tester.tap(find.byType(SourcePickerPill));
    await tester.pumpAndSettle();
    await tester.tap(find.text('混合 · 全部源').last);
    await tester.pumpAndSettle();
    expect(find.text('混合 · 全部源'), findsOneWidget);
    expect(instances['anime-a']!.last.discoveryCalls, 1);
    expect(instances['anime-b']!.last.discoveryCalls, 1);

    harness.library.feedLayout = FeedLayout.list;
    await tester.pump();

    expect(find.text('混合 · 全部源'), findsOneWidget);
    expect(instances['anime-a']!.last.discoveryCalls, 1);
    expect(instances['anime-b']!.last.discoveryCalls, 1);

    final mixedA = instances['anime-a']!.last;
    final mixedB = instances['anime-b']!.last;
    harness.library.setSourceEnabled('anime-b', false, 2);
    await tester.pumpAndSettle();

    expect(find.text('混合 · 全部源'), findsOneWidget);
    expect(mixedA.disposed, isTrue);
    expect(mixedB.disposed, isTrue);
    expect(instances['anime-a']!.last.discoveryCalls, 1);
  });

  testWidgets('stale anime results do not survive a new search',
      (tester) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: true,
      instances: instances,
      sources: const [
        SourceMeta(id: 'anime-a', name: '番剧 A', script: '', kind: 'anime'),
      ],
      settle: false,
      sourceFactory: (meta, _) => _FakeAnimeSource(
        meta,
        gate: gate.future,
        discoveryResult: const Paged([Manga(id: 'old', title: '旧结果')]),
        searchResult: const Paged([Manga(id: 'new', title: '新结果')]),
      ),
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });

    tester.state<AnimeBrowserState>(find.byType(AnimeBrowser)).runSearch('新查询');
    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('旧结果'), findsNothing);
    expect(find.text('新结果'), findsOneWidget);
    expect(instances['anime-a']!.single.searchCalls, 1);
  });

  testWidgets('mixed translation fallback is prepared once after all sources',
      (tester) async {
    var variantCalls = 0;
    String? variantQuery;
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: instances,
      searchVariants: (query, library) async {
        variantCalls++;
        variantQuery = query;
        return const ['翻译名称'];
      },
      sourceFactory: (meta, _) => _FakeAnimeSource(
        meta,
        searchHandler: (query, page) async =>
            query == '翻译名称' && meta.id == 'anime-a'
                ? const Paged([Manga(id: 'translated', title: '翻译命中')])
                : const Paged([]),
      ),
    );
    addTearDown(() {
      harness.library.dispose();
      harness.controller.dispose();
    });

    tester
        .state<AnimeBrowserState>(find.byType(AnimeBrowser))
        .runSearch('原始名称');
    await tester.pumpAndSettle();

    expect(variantCalls, 1);
    expect(variantQuery, '原始名称');
    expect(find.text('翻译命中'), findsOneWidget);
    expect(instances['anime-a']!.single.searchCalls, 2);
    expect(instances['anime-b']!.single.searchCalls, 2);
  });

  testWidgets('Bili login bar is limited to the selected Bili source',
      (tester) async {
    const bili = SourceMeta(
      id: kBiliSourceId,
      name: '哔哩哔哩',
      script: '',
      kind: 'anime',
    );
    final mixedInstances = <String, List<_FakeAnimeSource>>{};
    final mixed = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: mixedInstances,
      sources: const [
        bili,
        SourceMeta(id: 'anime-a', name: '番剧 A', script: '', kind: 'anime'),
      ],
    );
    expect(find.textContaining('登录后可看追番'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    mixed.library.dispose();
    mixed.controller.dispose();

    final selectedInstances = <String, List<_FakeAnimeSource>>{};
    final selected = await _pumpBrowser(
      tester,
      showSourcePicker: true,
      instances: selectedInstances,
      sources: const [bili],
    );
    addTearDown(() {
      selected.library.dispose();
      selected.controller.dispose();
    });
    expect(find.textContaining('登录后可看追番'), findsOneWidget);
  });

  testWidgets('disposing anime browser invalidates pending source loads',
      (tester) async {
    final gate = Completer<void>();
    final instances = <String, List<_FakeAnimeSource>>{};
    final harness = await _pumpBrowser(
      tester,
      showSourcePicker: false,
      instances: instances,
      settle: false,
      sourceFactory: (meta, _) => _FakeAnimeSource(
        meta,
        gate: gate.future,
        discoveryResult: const Paged([Manga(id: 'late', title: '迟到结果')]),
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.pump();

    expect(
      instances.values.expand((sources) => sources).every((s) => s.disposed),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    harness.library.dispose();
    harness.controller.dispose();
  });
}
