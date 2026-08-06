// The fake accepts these controls for follow-up mixed-source scenarios.
// ignore_for_file: unused_element_parameter

import 'dart:async';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/source_controller.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
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
  String? savedSourceId,
  _FakeAnimeSource Function(SourceMeta meta, int buildIndex)? sourceFactory,
  bool settle = true,
}) async {
  SharedPreferences.setMockInitialValues({
    if (savedSourceId != null) 'source.current.anime': savedSourceId,
  });
  registeredSources = [..._sources];
  final library = LibraryStore();
  await library.load();
  library.showSourcePicker = showSourcePicker;
  final controller = SourceController(_sources.first);
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
            sourceCatalog: _sources,
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

    expect(instances['anime-a'], hasLength(2));
    expect(instances['anime-a']!.last.discoveryCalls, 1);

    oldGate.complete();
    await tester.pump();
  });
}
