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
import 'package:dream_manga_reader/features/common/source_picker.dart';
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

Future<({LibraryStore library, SourceController controller})> _pumpBrowser(
  WidgetTester tester, {
  required bool showSourcePicker,
  required Map<String, List<_FakeAnimeSource>> instances,
  List<SourceMeta> sources = _sources,
  String? savedSourceId,
  _FakeAnimeSource Function(SourceMeta meta, int buildIndex)? sourceFactory,
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
    home: LibraryScope(
      store: library,
      child: SourceScope(
        controller: controller,
        child: Scaffold(
          body: AnimeBrowser(
            sourceBuilder: build,
            sourceCatalog: sources,
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
}
