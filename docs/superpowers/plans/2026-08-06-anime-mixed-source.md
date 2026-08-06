# Anime Mixed Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让番剧浏览页与漫画一致地支持设置控制的混合源模式和可手选的单一目标源。

**Architecture:** 在 `AnimeBrowser` 内增加独立的混合源游标、结果来源绑定、标题去重和加载代际，不重构漫画或小说。浏览器通过可选的源构建器与源目录保持可测性；正式调用仍默认使用 `buildSource` 和 `registeredSources`，详情页继续使用结果自身的 `SourceMeta`。

**Tech Stack:** Flutter、Dart、`MangaSource`、`SourceController`、Flutter Widget Tests

---

## File Structure

- Modify: `lib/features/anime/anime_browser.dart`
  - 增加来源依赖注入、单源/混合源状态、独立分页、去重、错误隔离、设置联动和正确详情跳转。
- Create: `test/anime_browser_mixed_source_test.dart`
  - 用可控假番剧源覆盖混合设置、切源、并发加载、去重、错误、陈旧请求和 B 站登录条。

### Task 1: Configure Anime Sources From Settings And SourceController

**Files:**
- Modify: `lib/features/anime/anime_browser.dart:1-90,150-180`
- Create: `test/anime_browser_mixed_source_test.dart`

- [ ] **Step 1: Write failing tests for forced mixed mode and visible source selection**

创建 `test/anime_browser_mixed_source_test.dart`，先建立可复用假源与页面外壳：

```dart
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

const sourceA = SourceMeta(
  id: 'anime-a',
  name: '番剧源 A',
  script: '',
  kind: 'anime',
);
const sourceB = SourceMeta(
  id: 'anime-b',
  name: '番剧源 B',
  script: '',
  kind: 'anime',
);

class _FakeAnimeSource implements MangaSource {
  _FakeAnimeSource(
    this.meta, {
    this.discovery = const Paged<Manga>([]),
    this.search = const Paged<Manga>([]),
    this.error,
    this.gate,
    this.discoveryHandler,
    this.searchHandler,
  });

  final SourceMeta meta;
  final Paged<Manga> discovery;
  final Paged<Manga> search;
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
  String get baseUrl => '';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;

  @override
  Future<Paged<Manga>> getDiscovery(
    int page, {
    Map<String, Object?>? filters,
  }) async {
    discoveryCalls++;
    discoveryPages.add(page);
    await gate;
    if (error != null) throw error!;
    if (discoveryHandler != null) return discoveryHandler!(page);
    return discovery;
  }

  @override
  Future<Paged<Manga>> getSearch(
    String query,
    int page, {
    Map<String, Object?>? filters,
  }) async {
    searchCalls++;
    await gate;
    if (error != null) throw error!;
    if (searchHandler != null) return searchHandler!(query, page);
    return search;
  }

  @override
  Future<Manga> getMangaDetail(String mangaId) async =>
      Manga(id: mangaId, title: mangaId);
  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) async =>
      const Paged<Chapter>([]);
  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) async =>
      const [];

  @override
  void dispose() => disposed = true;
}

class _Harness {
  _Harness(this.library, this.controller, this.instances);
  final LibraryStore library;
  final SourceController controller;
  final Map<String, _FakeAnimeSource> instances;
}

Future<_Harness> pumpAnimeBrowser(
  WidgetTester tester, {
  required bool showSourcePicker,
  List<SourceMeta> sources = const [sourceA, sourceB],
  _FakeAnimeSource Function(SourceMeta meta)? factory,
  AnimeSearchVariants? searchVariants,
}) async {
  SharedPreferences.setMockInitialValues({});
  registeredSources = [...sources];
  final library = LibraryStore();
  await library.load();
  library.showSourcePicker = showSourcePicker;
  final controller = SourceController(sources.firstOrNull);
  await controller.load();
  final instances = <String, _FakeAnimeSource>{};

  MangaSource build(SourceMeta meta) {
    final instance = factory?.call(meta) ?? _FakeAnimeSource(meta);
    instances[meta.id] = instance;
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
            sourceCatalog: sources,
            sourceBuilder: build,
            searchVariants: searchVariants,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  return _Harness(library, controller, instances);
}

void disposeHarness(_Harness harness) {
  harness.library.dispose();
  harness.controller.dispose();
  registeredSources = [];
}

void main() {
  testWidgets('hidden picker forces all enabled anime sources', (tester) async {
    final harness = await pumpAnimeBrowser(
      tester,
      showSourcePicker: false,
    );
    addTearDown(() => disposeHarness(harness));
    await tester.pumpAndSettle();

    expect(find.byType(SourcePickerPill), findsNothing);
    expect(harness.instances.keys, containsAll(['anime-a', 'anime-b']));
    expect(harness.instances['anime-a']!.discoveryCalls, 1);
    expect(harness.instances['anime-b']!.discoveryCalls, 1);
  });

  testWidgets('visible picker starts from saved anime source', (tester) async {
    final harness = await pumpAnimeBrowser(
      tester,
      showSourcePicker: true,
    );
    addTearDown(() => disposeHarness(harness));
    await tester.pumpAndSettle();

    expect(find.byType(SourcePickerPill), findsOneWidget);
    expect(find.textContaining('番剧源 A'), findsOneWidget);
    expect(harness.instances.keys, ['anime-a']);
    expect(harness.instances['anime-a']!.discoveryCalls, 1);
  });

  testWidgets('runtime source settings rebuild the forced mixed set',
      (tester) async {
    final harness = await pumpAnimeBrowser(
      tester,
      showSourcePicker: false,
    );
    addTearDown(() => disposeHarness(harness));
    await tester.pumpAndSettle();
    final oldA = harness.instances['anime-a']!;
    final oldB = harness.instances['anime-b']!;

    harness.library.setSourceEnabled('anime-b', false, 2);
    await tester.pumpAndSettle();

    expect(oldA.disposed, isTrue);
    expect(oldB.disposed, isTrue);
    expect(harness.instances['anime-a'], isNot(same(oldA)));
    expect(harness.instances['anime-a']!.discoveryCalls, 1);
    expect(harness.instances['anime-b'], same(oldB));
  });
}
```

- [ ] **Step 2: Run the new tests and verify constructor/settings failures**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test\anime_browser_mixed_source_test.dart
```

Expected: FAIL because `AnimeBrowser` does not accept `sourceCatalog` / `sourceBuilder`, and it does not force mixed mode from `showSourcePicker`.

- [ ] **Step 3: Add injectable source dependencies and source state types**

在 `anime_browser.dart` 顶部加入 `dart:async`、`SourceController`、`ChineseFold` 和 `search_rank` 导入，然后把组件签名改为：

```dart
typedef AnimeSourceFactory = MangaSource Function(SourceMeta meta);
typedef AnimeSearchVariants = Future<List<String>> Function(
  String query,
  LibraryStore library,
);

class AnimeBrowser extends StatefulWidget {
  const AnimeBrowser({
    super.key,
    this.sourceBuilder = buildSource,
    this.sourceCatalog,
    this.searchVariants,
  });

  final AnimeSourceFactory sourceBuilder;
  final List<SourceMeta>? sourceCatalog;
  final AnimeSearchVariants? searchVariants;

  @override
  State<AnimeBrowser> createState() => AnimeBrowserState();
}

class _AnimeResult {
  _AnimeResult({required this.anime, required this.meta});

  final Manga anime;
  final SourceMeta meta;
  final Set<String> sourceIds = {};
}

class _AnimeCursor {
  _AnimeCursor(this.meta, this.source);

  final SourceMeta meta;
  final MangaSource source;
  int page = 1;
  bool hasNext = true;
  bool loading = false;
  bool failed = false;
}
```

把 State 的核心字段替换/扩展为：

```dart
static const _mixedId = '__anime_all__';

SourceController? _sourceController;
SourceMeta? _meta;
MangaSource? _source;
final List<_AnimeCursor> _mixedSources = [];
final List<_AnimeResult> _results = [];
final Map<String, _AnimeResult> _byTitle = {};
final Set<String> _failedSources = {};
int _page = 1;
int _loadGeneration = 0;
bool _initialized = false;
bool _mixed = true;
bool? _showSourcePicker;
String _enabledSourceSignature = '';
bool _loading = false;
bool _hasNext = true;
Object? _error;
```

- [ ] **Step 4: Configure sources from settings and SourceController**

用以下逻辑替换原 `_animeSources`、`_pickDefault` 和 `_useSource`：

```dart
List<SourceMeta> get _enabledSources {
  final library = LibraryScope.read(context);
  return [
    for (final source in widget.sourceCatalog ?? registeredSources)
      if (source.isAnime && library.isSourceEnabled(source.id)) source,
  ];
}

@override
void didChangeDependencies() {
  super.didChangeDependencies();
  final controller = SourceScope.of(context);
  final controllerChanged = controller != _sourceController;
  if (controllerChanged) {
    _sourceController?.removeListener(_onSelectedSourceChanged);
    _sourceController = controller..addListener(_onSelectedSourceChanged);
  }
  final showSourcePicker = LibraryScope.of(context).showSourcePicker;
  final settingChanged = showSourcePicker != _showSourcePicker;
  final sourceSignature = _enabledSources.map((source) => source.id).join('\u0000');
  if (!_initialized ||
      controllerChanged ||
      settingChanged ||
      sourceSignature != _enabledSourceSignature) {
    if (!showSourcePicker) {
      _mixed = true;
    } else if (!_initialized || settingChanged) {
      // 从强制混合恢复为可选择模式时，回到已持久化的番剧单源。
      _mixed = false;
    }
    _initialized = true;
    _showSourcePicker = showSourcePicker;
    _enabledSourceSignature = sourceSignature;
    _configureSources();
  }
}

void _onSelectedSourceChanged() {
  if (!_mixed) _configureSources();
}

void _disposeSources() {
  _source?.dispose();
  _source = null;
  for (final cursor in _mixedSources) {
    cursor.source.dispose();
  }
  _mixedSources.clear();
}

void _configureSources() {
  _disposeSources();
  final sources = _enabledSources;
  if (_mixed) {
    _meta = null;
    for (final meta in sources) {
      _mixedSources.add(_AnimeCursor(meta, widget.sourceBuilder(meta)));
    }
  } else {
    final selected = _sourceController?.currentFor('anime');
    _meta = sources.where((item) => item.id == selected?.id).firstOrNull ??
        sources.firstOrNull;
    final meta = _meta;
    if (meta != null) _source = widget.sourceBuilder(meta);
  }
  _reset();
}
```

在 `build` 中只在设置开启时显示胶囊，标签按模式变化：

```dart
final library = LibraryScope.of(context);
if (library.showSourcePicker)
  Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
    child: SourcePickerPill(
      label: _mixed
          ? context.l10n.disc_mixedAllSources
          : '${_meta?.name ?? ''} · 番剧',
      icon: _mixed ? Icons.dashboard_rounded : Icons.movie_rounded,
      onTap: _pickSource,
    ),
  ),
```

- [ ] **Step 5: Run the settings tests**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test\anime_browser_mixed_source_test.dart
```

Expected: 3 tests PASS; picker hidden builds both sources, picker visible builds only the saved anime source, and a runtime source-disable notification disposes/rebuilds the active mixed set.

- [ ] **Step 6: Commit source configuration**

```powershell
$ErrorActionPreference = 'Stop'
git add lib\features\anime\anime_browser.dart test\anime_browser_mixed_source_test.dart
git commit -m "feat(anime): configure mixed and selected sources"
```

### Task 2: Load, Deduplicate, And Paginate Mixed Anime Results

**Files:**
- Modify: `lib/features/anime/anime_browser.dart:80-155,200-285`
- Modify: `test/anime_browser_mixed_source_test.dart`

- [ ] **Step 1: Add failing mixed-result and failure-isolation tests**

在测试文件导入 `ChineseFold`，并加入：

```dart
testWidgets('mixed anime isolates failures and deduplicates titles',
    (tester) async {
  await ChineseFold.load();
  final harness = await pumpAnimeBrowser(
    tester,
    showSourcePicker: false,
    sources: const [
      sourceA,
      sourceB,
      SourceMeta(
        id: 'anime-broken',
        name: '故障源',
        script: '',
        kind: 'anime',
      ),
    ],
    factory: (meta) => switch (meta.id) {
      'anime-a' => _FakeAnimeSource(
          meta,
          discovery: const Paged([
            Manga(id: 'a-1', title: '刀剑神域'),
          ]),
        ),
      'anime-b' => _FakeAnimeSource(
          meta,
          discovery: const Paged([
            Manga(id: 'b-1', title: '刀劍神域'),
          ]),
        ),
      _ => _FakeAnimeSource(meta, error: StateError('timeout')),
    },
  );
  addTearDown(() => disposeHarness(harness));
  await tester.pumpAndSettle();

  expect(find.text('刀剑神域'), findsOneWidget);
  expect(find.text('刀劍神域'), findsNothing);
  expect(find.text('2源'), findsOneWidget);
  expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
});

testWidgets('all failed anime sources expose retry', (tester) async {
  final harness = await pumpAnimeBrowser(
    tester,
    showSourcePicker: false,
    factory: (meta) => _FakeAnimeSource(meta, error: Exception(meta.id)),
  );
  addTearDown(() => disposeHarness(harness));
  await tester.pumpAndSettle();

  expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
  expect(find.text('重试'), findsOneWidget);
});

testWidgets('a slow anime source does not block a fast source next page',
    (tester) async {
  final slowGate = Completer<void>();
  final harness = await pumpAnimeBrowser(
    tester,
    showSourcePicker: false,
    factory: (meta) {
      if (meta.id == 'anime-b') {
        return _FakeAnimeSource(meta, gate: slowGate.future);
      }
      return _FakeAnimeSource(
        meta,
        discoveryHandler: (page) async => page == 1
            ? Paged(
                List.generate(
                  30,
                  (index) => Manga(id: 'a-$index', title: '快速番剧 $index'),
                ),
                hasNext: true,
              )
            : const Paged([]),
      );
    },
  );
  addTearDown(() => disposeHarness(harness));
  await tester.pump();

  expect(find.text('快速番剧 0'), findsOneWidget);
  await tester.fling(
    find.byType(GridView),
    const Offset(0, -2400),
    1200,
  );
  await tester.pump();

  expect(harness.instances['anime-a']!.discoveryPages, [1, 2]);
  expect(harness.instances['anime-b']!.discoveryPages, [1]);
  slowGate.complete();
  await tester.pumpAndSettle();
});
```

- [ ] **Step 2: Run tests and verify mixed results are not yet represented**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test\anime_browser_mixed_source_test.dart
```

Expected: new tests FAIL because `_results` still stores plain `Manga` and mixed cursors are not loaded or deduplicated.

- [ ] **Step 3: Reset both modes with a new generation**

用以下 `_reset` 替换旧实现：

```dart
void _reset() {
  _loadGeneration++;
  for (final cursor in _mixedSources) {
    cursor
      ..page = 1
      ..hasNext = true
      ..loading = false
      ..failed = false;
  }
  setState(() {
    _results.clear();
    _byTitle.clear();
    _failedSources.clear();
    _page = 1;
    _loading = false;
    _hasNext = true;
    _error = null;
  });
  unawaited(_loadMore());
}
```

- [ ] **Step 4: Implement single and mixed loading with isolated cursors**

用以下结构替换 `_loadMore`，并新增 `_loadMixedCursor`：

```dart
Future<void> _loadMore() async {
  if (_mixed) {
    if (_mixedSources.isEmpty) return;
    final generation = _loadGeneration;
    for (final cursor in _mixedSources) {
      unawaited(_loadMixedCursor(cursor, generation));
    }
    return;
  }

  if (_loading || !_hasNext || _source == null) return;
  final generation = _loadGeneration;
  setState(() => _loading = true);
  try {
    final result = _query.isEmpty
        ? await _source!.getDiscovery(_page)
        : await _source!.getSearch(_query, _page);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      for (final anime in result.items) {
        _addResult(anime, _meta!);
      }
      _page++;
      _hasNext = result.hasNext && result.items.isNotEmpty;
      _loading = false;
      _error = null;
      _sortResults();
    });
  } catch (error) {
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loading = false;
      _error = error;
    });
  }
  await _maybeFallback(generation);
}

Future<void> _loadMixedCursor(
  _AnimeCursor cursor,
  int generation,
) async {
  if (cursor.loading || !cursor.hasNext) return;
  cursor.loading = true;
  if (mounted) setState(_recomputeMixedFlags);
  try {
    final result = _query.isEmpty
        ? await cursor.source.getDiscovery(cursor.page)
        : await cursor.source.getSearch(_query, cursor.page);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      for (final anime in result.items) {
        _addResult(anime, cursor.meta);
      }
      cursor.page++;
      cursor.hasNext = result.hasNext && result.items.isNotEmpty;
      cursor.failed = false;
      _failedSources.remove(cursor.meta.id);
      _sortResults();
    });
  } catch (_) {
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      cursor.failed = true;
      cursor.hasNext = false;
      _failedSources.add(cursor.meta.id);
    });
  } finally {
    if (generation == _loadGeneration) {
      cursor.loading = false;
      if (mounted) {
        setState(_recomputeMixedFlags);
        await _maybeFallback(generation);
      }
    }
  }
}

void _recomputeMixedFlags() {
  _loading = _mixedSources.any((cursor) => cursor.loading);
  _hasNext = _mixedSources.any((cursor) => cursor.hasNext);
  if (!_loading &&
      _results.isEmpty &&
      _mixedSources.isNotEmpty &&
      _failedSources.length == _mixedSources.length) {
    _error = StateError(context.l10n.disc_allSourcesFailed);
  }
}
```

- [ ] **Step 5: Bind each result to its representative source and deduplicate titles**

新增：

```dart
void _addResult(Manga anime, SourceMeta meta) {
  final key = ChineseFold.dedupKey(anime.title);
  if (key.isEmpty) {
    final result = _AnimeResult(anime: anime, meta: meta)
      ..sourceIds.add(meta.id);
    _results.add(result);
    return;
  }
  final existing = _byTitle[key];
  if (existing != null) {
    existing.sourceIds.add(meta.id);
    return;
  }
  final result = _AnimeResult(anime: anime, meta: meta)
    ..sourceIds.add(meta.id);
  _byTitle[key] = result;
  _results.add(result);
}

void _sortResults() {
  if (_origQuery.isEmpty) return;
  _results.sort((a, b) => searchRelevance(
        b.anime.title,
        _origQuery,
      ).compareTo(searchRelevance(a.anime.title, _origQuery)));
}
```

在网格中把 `final m = _results[i]` 替换为：

```dart
final result = _results[i];
final anime = result.anime;
return Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Flexible(
      child: MangaCover(
        manga: anime,
        headers: imageHeadersOf(result.meta),
        sourceCount: result.sourceIds.length,
        heroTag: 'anime:${result.meta.id}:${anime.id}:$i',
        onTap: () => _open(result),
      ),
    ),
    const SizedBox(height: 6),
    Text(
      anime.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: p.textPrimary,
      ),
    ),
  ],
);
```

- [ ] **Step 6: Run mixed-result tests**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test\anime_browser_mixed_source_test.dart
```

Expected: 6 tests PASS; two title variants become one card with `2源`, one failed source does not replace successful content, all failures expose retry, and a slow cursor does not block a fast cursor's second page.

- [ ] **Step 7: Commit mixed loading**

```powershell
$ErrorActionPreference = 'Stop'
git add lib\features\anime\anime_browser.dart test\anime_browser_mixed_source_test.dart
git commit -m "feat(anime): merge enabled source results"
```

### Task 3: Switch Sources And Open The Correct Anime Detail

**Files:**
- Modify: `lib/features/anime/anime_browser.dart:150-205,285-350`
- Modify: `test/anime_browser_mixed_source_test.dart`

- [ ] **Step 1: Add failing source-picker and representative-source tests**

先在测试文件加入详情页导入：

```dart
import 'package:dream_manga_reader/features/anime/anime_detail_page.dart';
```

再加入：

```dart
testWidgets('anime picker persists a selected source', (tester) async {
  final harness = await pumpAnimeBrowser(tester, showSourcePicker: true);
  addTearDown(() => disposeHarness(harness));
  await tester.pumpAndSettle();
  final oldA = harness.instances['anime-a']!;

  await tester.tap(find.byType(SourcePickerPill));
  await tester.pumpAndSettle();
  await tester.tap(find.text('番剧源 B').last);
  await tester.pumpAndSettle();

  expect(harness.controller.currentFor('anime')?.id, 'anime-b');
  expect(find.textContaining('番剧源 B'), findsOneWidget);
  expect(oldA.disposed, isTrue);
  expect(harness.instances['anime-b']!.discoveryCalls, 1);
});

testWidgets('mixed anime card opens detail with its representative source',
    (tester) async {
  final harness = await pumpAnimeBrowser(
    tester,
    showSourcePicker: false,
    factory: (meta) => _FakeAnimeSource(
      meta,
      discovery: meta.id == 'anime-b'
          ? const Paged([Manga(id: 'b-show', title: '代表番剧')])
          : const Paged([]),
    ),
  );
  addTearDown(() => disposeHarness(harness));
  await tester.pumpAndSettle();

  await tester.tap(find.text('代表番剧'));
  await tester.pump();

  final detail = tester.widget<AnimeDetailPage>(find.byType(AnimeDetailPage));
  expect(detail.meta.id, 'anime-b');
  expect(detail.anime.id, 'b-show');
});

testWidgets('manual mixed mode survives unrelated library notifications',
    (tester) async {
  final harness = await pumpAnimeBrowser(tester, showSourcePicker: true);
  addTearDown(() => disposeHarness(harness));
  await tester.pumpAndSettle();

  await tester.tap(find.byType(SourcePickerPill));
  await tester.pumpAndSettle();
  await tester.tap(find.text('混合 · 全部源').last);
  await tester.pumpAndSettle();
  expect(find.text('混合 · 全部源'), findsOneWidget);
  expect(harness.instances.keys, containsAll(['anime-a', 'anime-b']));

  harness.library.feedLayout = FeedLayout.list;
  await tester.pump();

  expect(find.text('混合 · 全部源'), findsOneWidget);
  expect(harness.instances['anime-a']!.discoveryCalls, 1);
  expect(harness.instances['anime-b']!.discoveryCalls, 1);
});
```

- [ ] **Step 2: Run tests and verify picker/detail routing failures**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test\anime_browser_mixed_source_test.dart
```

Expected: new tests FAIL because the picker excludes mixed mode and `_open` still reads the page-level `_meta`.

- [ ] **Step 3: Implement mixed/single source selection**

替换 `_pickSource`：

```dart
Future<void> _pickSource() async {
  final selected = await showSourcePicker(
    context,
    currentId: _mixed ? _mixedId : (_meta?.id ?? ''),
    includeMixed: true,
    mixedId: _mixedId,
    kind: 'anime',
  );
  if (selected == null || !mounted) return;
  if (selected == _mixedId) {
    if (_mixed) return;
    _mixed = true;
    _configureSources();
    return;
  }
  final meta =
      _enabledSources.where((item) => item.id == selected).firstOrNull;
  if (meta == null) return;
  _mixed = false;
  final controller = _sourceController;
  if (controller?.currentFor('anime')?.id == meta.id) {
    _configureSources();
  } else {
    controller?.selectFor('anime', meta);
  }
}
```

- [ ] **Step 4: Route detail from the result's own source**

将 `_open` 改为：

```dart
void _open(_AnimeResult result) {
  Navigator.of(context).push(appRoute(AnimeDetailPage(
    meta: result.meta,
    anime: result.anime,
    sourceBuilder: widget.sourceBuilder,
  )));
}
```

`_isBili` 必须限定单源：

```dart
bool get _isBili => !_mixed && _meta?.id == kBiliSourceId;
```

- [ ] **Step 5: Run picker and routing tests**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test\anime_browser_mixed_source_test.dart
```

Expected: 9 tests PASS; selected source persists, old source is disposed, the detail widget receives the representative source, and unrelated library notifications preserve manually selected mixed mode.

- [ ] **Step 6: Commit picker and detail routing**

```powershell
$ErrorActionPreference = 'Stop'
git add lib\features\anime\anime_browser.dart test\anime_browser_mixed_source_test.dart
git commit -m "feat(anime): switch and preserve result sources"
```

### Task 4: Reject Stale Requests And Preserve Search Fallback

**Files:**
- Modify: `lib/features/anime/anime_browser.dart:90-150,205-285,350-390`
- Modify: `test/anime_browser_mixed_source_test.dart`

- [ ] **Step 1: Add failing stale-request and Bili-boundary tests**

先加入 B 站源 ID 导入：

```dart
import 'package:dream_manga_reader/core/bili/bili_auth.dart';
```

再加入：

```dart
testWidgets('stale anime results do not survive a new search', (tester) async {
  final oldGate = Completer<void>();
  late _FakeAnimeSource source;
  final harness = await pumpAnimeBrowser(
    tester,
    showSourcePicker: true,
    sources: const [sourceA],
    factory: (meta) => source = _FakeAnimeSource(
      meta,
      discovery: const Paged([Manga(id: 'old', title: '旧结果')]),
      search: const Paged([Manga(id: 'new', title: '新结果')]),
      gate: oldGate.future,
    ),
  );
  addTearDown(() => disposeHarness(harness));

  final key = tester.state<AnimeBrowserState>(find.byType(AnimeBrowser));
  key.runSearch('新查询');
  oldGate.complete();
  await tester.pumpAndSettle();

  expect(find.text('旧结果'), findsNothing);
  expect(find.text('新结果'), findsOneWidget);
  expect(source.searchCalls, 1);
});

testWidgets('mixed translation fallback is prepared once after all sources',
    (tester) async {
  var variantCalls = 0;
  final harness = await pumpAnimeBrowser(
    tester,
    showSourcePicker: false,
    searchVariants: (query, library) async {
      variantCalls++;
      expect(query, '原始名称');
      return const ['翻译名称'];
    },
    factory: (meta) => _FakeAnimeSource(
      meta,
      searchHandler: (query, page) async =>
          query == '翻译名称' && meta.id == 'anime-a'
              ? const Paged([Manga(id: 'translated', title: '翻译命中')])
              : const Paged([]),
    ),
  );
  addTearDown(() => disposeHarness(harness));

  tester.state<AnimeBrowserState>(find.byType(AnimeBrowser)).runSearch('原始名称');
  await tester.pumpAndSettle();

  expect(variantCalls, 1);
  expect(find.text('翻译命中'), findsOneWidget);
  expect(harness.instances['anime-a']!.searchCalls, 2);
  expect(harness.instances['anime-b']!.searchCalls, 2);
});

testWidgets('Bili login bar is limited to the selected Bili source',
    (tester) async {
  const bili = SourceMeta(
    id: kBiliSourceId,
    name: '哔哩哔哩',
    script: '',
    kind: 'anime',
  );
  final mixed = await pumpAnimeBrowser(
    tester,
    showSourcePicker: false,
    sources: const [bili, sourceA],
  );
  expect(find.textContaining('扫码登录'), findsNothing);
  await tester.pumpWidget(const SizedBox.shrink());
  disposeHarness(mixed);

  final selected = await pumpAnimeBrowser(
    tester,
    showSourcePicker: true,
    sources: const [bili],
  );
  addTearDown(() => disposeHarness(selected));
  await tester.pumpAndSettle();
  expect(find.textContaining('登录后可看追番'), findsOneWidget);
});

testWidgets('disposing anime browser invalidates pending source loads',
    (tester) async {
  final gate = Completer<void>();
  final harness = await pumpAnimeBrowser(
    tester,
    showSourcePicker: false,
    factory: (meta) => _FakeAnimeSource(
      meta,
      gate: gate.future,
      discovery: const Paged([Manga(id: 'late', title: '迟到结果')]),
    ),
  );

  await tester.pumpWidget(const SizedBox.shrink());
  gate.complete();
  await tester.pump();

  expect(harness.instances.values.every((source) => source.disposed), isTrue);
  expect(tester.takeException(), isNull);
  disposeHarness(harness);
});
```

- [ ] **Step 2: Run tests and verify stale-generation behavior**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test\anime_browser_mixed_source_test.dart
```

Expected: stale-result test FAIL until every async completion checks `_loadGeneration`; Bili boundary passes only after Task 3's `_isBili` change.

- [ ] **Step 3: Make search and fallback generation-aware**

将搜索入口保持为同步复位：

```dart
void runSearch(String query) {
  _query = query.trim();
  _origQuery = _query;
  _fallbackQueue = null;
  _reset();
}
```

把 `_maybeFallback` 改为接收当前代际，并仅在全部混合请求完成后运行：

```dart
Future<void> _maybeFallback(int generation) async {
  if (!mounted ||
      generation != _loadGeneration ||
      _loading ||
      _query.isEmpty ||
      _results.isNotEmpty ||
      _error != null ||
      !LibraryScope.read(context).translateSearch) {
    return;
  }
  if (_fallbackQueue == null) {
    _fallbackQueue = const [];
    final original = _origQuery;
    final store = LibraryScope.read(context);
    final variants = widget.searchVariants != null
        ? await widget.searchVariants!(original, store)
        : await TranslatedSearch.variants(
            original,
            providers: store.translateProviderOrder,
            targets: store.translateTargetsFor(original),
            llm: store.translateLlm,
          );
    if (!mounted || generation != _loadGeneration || _origQuery != original) {
      return;
    }
    _fallbackQueue = List.of(variants);
  }
  if (_fallbackQueue!.isNotEmpty) {
    _query = _fallbackQueue!.removeAt(0);
    _reset();
  }
}
```

所有单源和混合请求在修改结果、页码、错误前必须使用：

```dart
if (!mounted || generation != _loadGeneration) return;
```

- [ ] **Step 4: Invalidate requests and dispose listeners on teardown**

替换 `dispose`：

```dart
@override
void dispose() {
  _loadGeneration++;
  _sourceController?.removeListener(_onSelectedSourceChanged);
  _disposeSources();
  _scroll.dispose();
  super.dispose();
}
```

- [ ] **Step 5: Run the full anime-browser test file**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test\anime_browser_mixed_source_test.dart
```

Expected: 13 tests PASS; translation variants are prepared once after every mixed cursor settles, and disposal produces no post-dispose `setState`, stale result, timer, hit-test, or network warnings.

- [ ] **Step 6: Commit generation and lifecycle protection**

```powershell
$ErrorActionPreference = 'Stop'
git add lib\features\anime\anime_browser.dart test\anime_browser_mixed_source_test.dart
git commit -m "fix(anime): discard stale mixed source loads"
```

### Task 5: Final Regression And Scope Verification

**Files:**
- Verify: `lib/features/anime/anime_browser.dart`
- Verify: `test/anime_browser_mixed_source_test.dart`

- [ ] **Step 1: Format only files touched by this feature**

Run:

```powershell
$ErrorActionPreference = 'Stop'
dart format lib\features\anime\anime_browser.dart test\anime_browser_mixed_source_test.dart
```

Expected: formatter completes without touching unrelated files.

- [ ] **Step 2: Run focused anime and source regressions**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test\anime_browser_mixed_source_test.dart test\anime_detail_download_test.dart test\anime_favorite_test.dart test\anime_history_resume_test.dart test\source_kind_test.dart
```

Expected: all selected tests PASS.

- [ ] **Step 3: Run focused static analysis and diff validation**

Run:

```powershell
$ErrorActionPreference = 'Stop'
dart analyze lib\features\anime\anime_browser.dart test\anime_browser_mixed_source_test.dart
git diff --check
git status --short --branch
```

Expected: analyzer reports no issues, `git diff --check` has no output, and the worktree contains no uncommitted implementation changes.

- [ ] **Step 4: Verify the feature commit range and do not publish**

Run:

```powershell
$ErrorActionPreference = 'Stop'
git log --oneline 92e8362..HEAD
git diff --stat 92e8362..HEAD
```

Expected: the range contains only anime mixed-source implementation/test commits and changes only `anime_browser.dart` plus its test. Do not run Windows/Android builds, do not push, and do not create or update a PR.
