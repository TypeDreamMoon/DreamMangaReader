# Novel UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make novel source diagnostics, discovery, details, and reading layout match the established manga experience while preserving the current TXT, EPUB, online-source, download, progress, and sync systems.

**Architecture:** Route source health probes by content kind, reuse the existing `FeedLayout`/`FeedView` list system, and apply the manga detail page's narrow/wide composition to novel metadata plus a novel-specific lazy directory. Keep the existing WebView document engine, adding pure progress math, global reader preferences, responsive controls, and bounded CSS instead of replacing the renderer.

**Tech Stack:** Flutter/Dart, `flutter_inappwebview`, `shared_preferences`, existing app palette and source abstractions, Flutter widget/unit tests.

---

## Execution Rules

- Work only on `codex/novel-ui-polish`, based on `upstream/main@6b8269a`.
- Do not include the Picacg pagination commits or source repository files.
- Run all commands through PowerShell 7 with `-NoProfile` and `$ErrorActionPreference = 'Stop'`.
- Do not build Windows or Android packages. Validation is `flutter gen-l10n`, `flutter analyze`, focused tests, and the full Flutter suite.
- Keep generated `lib/l10n/app_localizations*.dart`, `.dart_tool`, `build`, `.tools`, and release output out of Git.

## File Map

### Create

- `test/source_health_test.dart`: verifies manga, anime, novel, unknown-kind, timeout, and disposal routing.
- `lib/features/novel/novel_feed_item.dart`: presentational card and list-tile widgets used by all novel feed layouts.
- `lib/features/novel/novel_book_progress.dart`: pure whole-book progress and slider-target conversion.
- `test/novel_book_progress_test.dart`: edge cases for progress calculation and target conversion.
- `lib/features/novel/novel_reader_chrome.dart`: top bar, bottom actions, progress slider, preview, and responsive positioning.

### Modify

- `lib/core/source/source_health.dart`: dispatch health probes by `SourceMeta.kind` and accept test builders.
- `lib/features/novel/novel_browser.dart`: replace the fixed grid with shared `FeedView` layouts.
- `test/novel_browser_test.dart`: verify all three shared layouts and novel card metadata.
- `lib/features/novel/novel_detail_page.dart`: adopt manga-style responsive hero/body structure and constrained lazy directory.
- `test/novel_detail_test.dart`: verify narrow/wide compositions, current chapter highlighting, and source switching.
- `lib/app/novel_library_store.dart`: persist toolbar auto-hide seconds with the existing global reader preferences.
- `lib/features/novel/novel_reader_settings_sheet.dart`: responsive panel, font stepper, theme swatches, layout sliders, and auto-hide slider.
- `test/novel_library_store_test.dart`: round-trip the new preference and legacy-data default.
- `lib/features/novel/novel_document_view.dart`: bound desktop text width and add safe wheel/click handling.
- `lib/features/novel/novel_reader_page.dart`: initial immersive state, timers, whole-book progress, keyboard behavior, and extracted chrome.
- `test/novel_reader_test.dart`: immersive controls, timer settings, progress drag, input, and locator preservation.
- `lib/l10n/app_zh.arb`, `lib/l10n/app_zh_Hant.arb`, `lib/l10n/app_en.arb`, `lib/l10n/app_ja.arb`: labels for progress and auto-hide settings.
- `test/l10n_test.dart`: maintain four-language key parity.

## Task 1: Route Source Health Checks by Content Kind

**Files:**
- Create: `test/source_health_test.dart`
- Modify: `lib/core/source/source_health.dart`

- [ ] **Step 1: Write failing routing tests**

Add fake `MangaSource` and `NovelSource` implementations that record calls and disposal. Cover the novel success path with this assertion shape:

```dart
test('novel health uses NovelSource discovery and disposes it', () async {
  final source = _FakeNovelSource(
    const Paged([Novel(id: 'n1', title: '诡秘之主', cover: 'cover')]),
  );
  final result = await checkSourceHealth(
    const SourceMeta(
      id: 'qidian',
      name: '起点中文网',
      script: '',
      kind: 'novel',
    ),
    novelBuilder: (_) => source,
    mangaBuilder: (_) => throw StateError('manga builder must not run'),
  );

  expect(result.status, SourceHealthStatus.ok);
  expect(result.count, 1);
  expect(result.log, contains('诡秘之主'));
  expect(source.discoveryCalls, 1);
  expect(source.disposed, isTrue);
});
```

Add separate tests for manga routing, unknown `kind`, empty discovery, thrown network error, timeout, and disposal after failure.

- [ ] **Step 2: Run the health tests and verify the novel test fails**

Run:

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\source_health_test.dart --reporter compact'
```

Expected: FAIL because `checkSourceHealth` has no injectable novel builder and calls `buildSource` for `kind: novel`.

- [ ] **Step 3: Implement typed probe routing**

Add builder typedefs and optional parameters:

```dart
typedef MangaHealthSourceBuilder = MangaSource Function(SourceMeta meta);
typedef NovelHealthSourceBuilder = NovelSource Function(SourceMeta meta);

Future<SourceHealthResult> checkSourceHealth(
  SourceMeta meta, {
  Duration timeout = const Duration(seconds: 25),
  MangaHealthSourceBuilder mangaBuilder = buildSource,
  NovelHealthSourceBuilder novelBuilder = buildNovelSource,
}) async {
```

Before probing, reject unsupported kinds. For supported kinds, use one branch per typed API and normalize the result into count, sample titles, and cover count:

```dart
if (!meta.isManga && !meta.isAnime && !meta.isNovel) {
  throw ArgumentError.value(
    meta.kind,
    'meta.kind',
    'expected manga, anime, or novel',
  );
}

if (meta.isNovel) {
  final source = novelBuilder(meta);
  dispose = source.dispose;
  final page = await source.getNovelDiscovery(1).timeout(timeout);
  count = page.items.length;
  sample = page.items.take(5).map((item) => item.title).join('、');
  withCover = page.items.where((item) => (item.cover ?? '').isNotEmpty).length;
} else {
  final source = mangaBuilder(meta);
  dispose = source.dispose;
  final page = await source.getDiscovery(1).timeout(timeout);
  count = page.items.length;
  sample = page.items.take(5).map((item) => item.title).join('、');
  withCover = page.items.where((item) => (item.cover ?? '').isNotEmpty).length;
}
```

Store `void Function()? dispose` and call it from `finally`. Preserve the existing log format and status mapping.

- [ ] **Step 4: Run focused and source-kind tests**

Run:

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\source_health_test.dart test\source_kind_test.dart --reporter compact'
```

Expected: all tests pass, and the Qidian-shaped metadata no longer reports `expected manga or anime`.

- [ ] **Step 5: Commit source diagnostics**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add -- lib/core/source/source_health.dart test/source_health_test.dart; git commit -m ''fix(sources): test novel health through novel protocol'''
```

## Task 2: Reuse Manga Feed Layouts for Novel Results

**Files:**
- Create: `lib/features/novel/novel_feed_item.dart`
- Modify: `lib/features/novel/novel_browser.dart`
- Modify: `test/novel_browser_test.dart`

- [ ] **Step 1: Write failing feed-layout widget tests**

Add a helper that pumps `NovelBrowser` with a chosen `LibraryStore.feedLayout`, then assert the shared feed receives that value:

```dart
for (final layout in FeedLayout.values) {
  testWidgets('novel results use ${layout.name} shared feed layout',
      (tester) async {
    final harness = await buildNovelBrowserHarness(layout: layout);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    final feed = tester.widget<FeedView>(find.byType(FeedView));
    expect(feed.layout, layout);
    expect(find.text('测试作者'), findsWidgets);
    expect(find.text('来源 A'), findsWidgets);

    harness.dispose();
  });
}
```

Use a novel with title, author, cover, description, and source metadata. Assert long labels do not throw after pumping at `390x844` and `1280x720`.

- [ ] **Step 2: Run the browser test and verify it fails**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_browser_test.dart --reporter compact'
```

Expected: FAIL because the page currently builds a fixed `GridView` and no `FeedView` exists.

- [ ] **Step 3: Add focused novel feed presentation widgets**

Create `NovelFeedCard` and `NovelFeedTile` with explicit inputs:

```dart
class NovelFeedCard extends StatelessWidget {
  const NovelFeedCard({
    super.key,
    required this.novel,
    required this.meta,
    required this.layout,
    required this.sourceCountLabel,
    required this.onTap,
  });

  final Novel novel;
  final SourceMeta meta;
  final FeedLayout layout;
  final String? sourceCountLabel;
  final VoidCallback onTap;
}

class NovelFeedTile extends StatelessWidget {
  const NovelFeedTile({
    super.key,
    required this.novel,
    required this.meta,
    required this.sourceCountLabel,
    required this.onTap,
  });

  final Novel novel;
  final SourceMeta meta;
  final String? sourceCountLabel;
  final VoidCallback onTap;
}
```

The card uses `aspectForId(novel.id)` only for masonry, `3 / 4` for grid, `NovelCover`, a two-line title, one-line author, and source pill. The tile uses a stable `72x96` cover, title, author, source, and two-line description. Use radius `8` or the current app palette radius and keep letter spacing unchanged.

- [ ] **Step 4: Replace the fixed grid with `FeedView`**

In `_content`, preserve empty/error/loading handling, then return:

```dart
return FeedView(
  layout: LibraryScope.of(context).feedLayout,
  controller: _scroll,
  itemCount: _results.length,
  cardBuilder: (context, index) {
    final result = _results[index];
    return NovelFeedCard(
      novel: result.novel,
      meta: result.meta,
      layout: LibraryScope.of(context).feedLayout,
      sourceCountLabel: result.sourceIds.length > 1
          ? context.l10n.novel_browserSourceCount(result.sourceIds.length)
          : null,
      onTap: () => _open(result),
    );
  },
  tileBuilder: (context, index) {
    final result = _results[index];
    return NovelFeedTile(
      novel: result.novel,
      meta: result.meta,
      sourceCountLabel: result.sourceIds.length > 1
          ? context.l10n.novel_browserSourceCount(result.sourceIds.length)
          : null,
      onTap: () => _open(result),
    );
  },
  footer: _loading ? const Center(child: CircularProgressIndicator()) : null,
);
```

- [ ] **Step 5: Run browser and shared feed tests**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_browser_test.dart test\novel_library_view_test.dart --reporter compact'
```

Expected: all tests pass in all three layouts.

- [ ] **Step 6: Commit shared novel feed layouts**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add -- lib/features/novel/novel_feed_item.dart lib/features/novel/novel_browser.dart test/novel_browser_test.dart; git commit -m ''feat(novel): match manga feed layouts'''
```

## Task 3: Align Novel Details with Manga Details

**Files:**
- Modify: `lib/features/novel/novel_detail_page.dart`
- Modify: `test/novel_detail_test.dart`

- [ ] **Step 1: Write failing narrow/wide detail tests**

Add surface-size tests with stable keys:

```dart
testWidgets('novel detail uses manga-style wide split layout', (tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(harness());
  await tester.pumpAndSettle();

  expect(find.byKey(const Key('novel-detail-hero')), findsOneWidget);
  expect(find.byKey(const Key('novel-detail-wide')), findsOneWidget);
  expect(find.byKey(const Key('novel-detail-directory')), findsOneWidget);
  expect(find.text('A1'), findsOneWidget);
});
```

Add a `390x844` test for `novel-detail-narrow`, an active-progress test that finds `novel-chapter-active`, and retain existing source-switch assertions.

- [ ] **Step 2: Run the detail tests and verify layout assertions fail**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_detail_test.dart --reporter compact'
```

Expected: FAIL because the responsive manga-style layout keys and split composition do not exist.

- [ ] **Step 3: Implement manga-style responsive composition**

Use the existing app palette and the same breakpoints as `DetailPage`:

```dart
body: DecoratedBox(
  decoration: BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [accent.withValues(alpha: .16), Colors.transparent],
      stops: const [0, .55],
    ),
  ),
  child: LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth >= 760
        ? _wideBody(context)
        : _narrowBody(context),
  ),
),
```

The narrow body is a centered `CustomScrollView` capped at `820`. The wide body is centered and capped at `1180`, with a `380`-pixel metadata column, divider, and independently scrolling lazy directory. Rebuild the hero with cover-derived/fallback gradient, `NovelCover`, source pill, title, author, status, and tags. Keep description, favorite, continue/start reading, browser, source switch, and download actions.

- [ ] **Step 4: Highlight the saved chapter without making the directory eager**

Read `NovelLibraryStore.progressFor(_libraryKey)` once per build and assign a key/selected style only to the matching lazy row:

```dart
final activeId = NovelLibraryScope.read(context)
    .progressFor(_libraryKey)
    ?.chapterId;

ListTile(
  key: chapter.id == activeId ? const Key('novel-chapter-active') : null,
  selected: chapter.id == activeId,
  leading: SizedBox(width: 42, child: Text('${index + 1}')),
  title: Text(chapter.title, maxLines: 2, overflow: TextOverflow.ellipsis),
  onTap: () => _openChapter(index),
  trailing: _chapterDownloadAction(chapter),
)
```

- [ ] **Step 5: Run detail and download integration tests**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_detail_test.dart test\novel_downloads_view_test.dart --reporter compact'
```

Expected: all tests pass and source switching still replaces, rather than merges, chapter lists.

- [ ] **Step 6: Commit novel detail alignment**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add -- lib/features/novel/novel_detail_page.dart test/novel_detail_test.dart; git commit -m ''feat(novel): align detail layout with manga'''
```

## Task 4: Add Global Reader Timing and Responsive Settings

**Files:**
- Modify: `lib/app/novel_library_store.dart`
- Modify: `lib/features/novel/novel_reader_settings_sheet.dart`
- Modify: `test/novel_library_store_test.dart`
- Modify: four `lib/l10n/app_*.arb` files
- Modify: `test/l10n_test.dart`

- [ ] **Step 1: Write failing preference round-trip tests**

Extend the existing preference test:

```dart
store.setPreferences(const NovelReaderPreferences(
  mode: NovelReaderMode.scroll,
  fontSize: 20,
  toolbarAutoHideSeconds: 7,
));
await store.flushPending();

final restored = NovelLibraryStore();
await restored.load();
expect(restored.preferences.toolbarAutoHideSeconds, 7);
```

Add a legacy JSON test with no new field and expect the default value `4`.

- [ ] **Step 2: Run the store test and verify it fails**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_library_store_test.dart --reporter compact'
```

Expected: FAIL because `toolbarAutoHideSeconds` is not defined.

- [ ] **Step 3: Extend and clamp the global preference model**

Add an integer field to `NovelReaderPreferences`:

```dart
const NovelReaderPreferences({
  this.mode = NovelReaderMode.paged,
  this.fontFamily = '',
  this.fontSize = 18,
  this.lineHeight = 1.7,
  this.paragraphSpacing = 10,
  this.horizontalMargin = 20,
  this.theme = NovelReaderTheme.sepia,
  this.keepScreenOn = true,
  this.toolbarAutoHideSeconds = 4,
});

final int toolbarAutoHideSeconds;
```

Include it in `copyWith`, `toJson`, and `fromJson`. Clamp deserialized values to `0..10`:

```dart
toolbarAutoHideSeconds:
    ((json['toolbarAutoHideSeconds'] as num?)?.toInt() ?? 4)
        .clamp(0, 10)
        .toInt(),
```

- [ ] **Step 4: Add localized labels and responsive settings controls**

Add the same keys to all four ARB files:

```json
"novel_readerAutoHide": "工具栏自动隐藏",
"novel_readerAutoHideOff": "关闭",
"novel_readerSeconds": "{seconds} 秒",
"@novel_readerSeconds": {
  "placeholders": { "seconds": { "type": "int" } }
}
```

Translate the values in Traditional Chinese, English, and Japanese. Run `flutter gen-l10n` before compiling tests.

In the settings UI, use `A-`/value/`A+` for font size, color swatches for themes, segmented mode controls, sliders for line height, paragraph spacing, margins, and auto-hide seconds, and a switch for keep-awake. The auto-hide slider is:

```dart
_SettingSlider(
  label: context.l10n.novel_readerAutoHide,
  value: _value.toolbarAutoHideSeconds.toDouble(),
  min: 0,
  max: 10,
  divisions: 10,
  valueLabel: _value.toolbarAutoHideSeconds == 0
      ? context.l10n.novel_readerAutoHideOff
      : context.l10n.novel_readerSeconds(_value.toolbarAutoHideSeconds),
  onChanged: (value) => _update(
    _value.copyWith(toolbarAutoHideSeconds: value.round()),
  ),
)
```

Use a bottom sheet below `700` logical pixels and a right-aligned, maximum `420`-pixel side panel at or above that width.

- [ ] **Step 5: Verify settings persistence and localization parity**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter gen-l10n; flutter test test\novel_library_store_test.dart test\l10n_test.dart --reporter compact'
```

Expected: preference round-trips, legacy defaults to `4`, and all four ARB files have identical keys.

- [ ] **Step 6: Commit global reader settings**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add -- lib/app/novel_library_store.dart lib/features/novel/novel_reader_settings_sheet.dart lib/l10n/app_zh.arb lib/l10n/app_zh_Hant.arb lib/l10n/app_en.arb lib/l10n/app_ja.arb test/novel_library_store_test.dart test/l10n_test.dart; git commit -m ''feat(novel): refine global reading settings'''
```

## Task 5: Add Pure Whole-Book Progress Mapping

**Files:**
- Create: `lib/features/novel/novel_book_progress.dart`
- Create: `test/novel_book_progress_test.dart`

- [ ] **Step 1: Write failing progress unit tests**

```dart
test('book progress combines chapter index and chapter fraction', () {
  expect(
    novelBookProgress(chapterIndex: 1, chapterFraction: .5, chapterCount: 4),
    closeTo(.375, 0.0001),
  );
});

test('slider target maps one to the final chapter end', () {
  expect(
    novelProgressTarget(progress: 1, chapterCount: 4),
    const NovelProgressTarget(chapterIndex: 3, chapterFraction: 1),
  );
});

test('progress helpers clamp invalid inputs', () {
  expect(novelBookProgress(chapterIndex: -2, chapterFraction: -1, chapterCount: 0), 0);
  expect(
    novelProgressTarget(progress: 2, chapterCount: 2),
    const NovelProgressTarget(chapterIndex: 1, chapterFraction: 1),
  );
});
```

- [ ] **Step 2: Run the new unit test and verify missing symbols**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_book_progress_test.dart --reporter compact'
```

Expected: FAIL because the progress helper file does not exist.

- [ ] **Step 3: Implement immutable target and pure conversion functions**

```dart
class NovelProgressTarget {
  const NovelProgressTarget({
    required this.chapterIndex,
    required this.chapterFraction,
  });

  final int chapterIndex;
  final double chapterFraction;

  @override
  bool operator ==(Object other) =>
      other is NovelProgressTarget &&
      other.chapterIndex == chapterIndex &&
      other.chapterFraction == chapterFraction;

  @override
  int get hashCode => Object.hash(chapterIndex, chapterFraction);
}

double novelBookProgress({
  required int chapterIndex,
  required double chapterFraction,
  required int chapterCount,
}) {
  if (chapterCount <= 0) return 0;
  final index = chapterIndex.clamp(0, chapterCount - 1).toInt();
  final fraction = (chapterFraction.isFinite ? chapterFraction : 0.0)
      .clamp(0.0, 1.0)
      .toDouble();
  return ((index + fraction) / chapterCount)
      .clamp(0.0, 1.0)
      .toDouble();
}
```

Implement `novelProgressTarget` so `progress == 1` maps to the last chapter at fraction `1`; other values use `scaled.floor()` and the fractional remainder.

- [ ] **Step 4: Run the pure progress tests**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_book_progress_test.dart --reporter compact'
```

Expected: all progress tests pass without widgets or network state.

- [ ] **Step 5: Commit progress math**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add -- lib/features/novel/novel_book_progress.dart test/novel_book_progress_test.dart; git commit -m ''feat(novel): map whole-book reading progress'''
```

## Task 6: Bound the Document and Harden Reader Input

**Files:**
- Modify: `lib/features/novel/novel_document_view.dart`
- Modify: `test/novel_reader_test.dart`

- [ ] **Step 1: Add failing HTML contract tests**

Extend the existing HTML shell test:

```dart
expect(html, contains('max(20px, calc((100vw - 760px) / 2))'));
expect(html, contains("closest?.('a,button,input,textarea,select,[contenteditable]')"));
expect(html, contains("addEventListener('wheel'"));
expect(html, contains("{passive:false}"));
```

Add an assertion that image width remains capped and CSP still contains `connect-src 'none'`.

- [ ] **Step 2: Run the reader test and verify the new contracts fail**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_reader_test.dart --reporter compact'
```

Expected: FAIL because desktop max-width and wheel handling are absent.

- [ ] **Step 3: Apply responsive bounded CSS**

Generate reader padding with the user's global margin and the desktop cap:

```javascript
body{
  margin:0;
  padding:22px max(${p.horizontalMargin}px, calc((100vw - 760px) / 2));
  font-family:${family ? `'${family}',` : ''}serif;
  font-size:${p.fontSize}px;
  line-height:${p.lineHeight};
  letter-spacing:0;
  overflow-wrap:anywhere;
}
p{margin:0 0 ${p.paragraphSpacing}px}
img{max-width:100%;height:auto}
```

Do not change CSP, sanitizer ordering, or resource caching.

- [ ] **Step 4: Ignore interactive content and add throttled wheel paging**

Before dividing click zones, return for interactive elements:

```javascript
const interactive = event.target.closest?.(
  'a,button,input,textarea,select,[contenteditable]'
);
if (interactive) return;
```

Add paged-mode wheel handling with a `250ms` lock and `preventDefault`; scroll mode keeps native scrolling:

```javascript
let lastWheelTurn = 0;
document.addEventListener('wheel', (event) => {
  if (mode !== 'paged' || Math.abs(event.deltaY) < 12) return;
  event.preventDefault();
  const now = Date.now();
  if (now - lastWheelTurn < 250) return;
  lastWheelTurn = now;
  window.flutter_inappwebview?.callHandler(
    'dmrCommand',
    event.deltaY > 0 ? 'next' : 'previous'
  );
}, {passive:false});
```

- [ ] **Step 5: Run sanitizer, cache, and reader tests**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_reader_test.dart test\novel_document_sanitizer_test.dart test\novel_document_cache_test.dart --reporter compact'
```

Expected: all tests pass and the security contract remains unchanged.

- [ ] **Step 6: Commit document layout and input**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add -- lib/features/novel/novel_document_view.dart test/novel_reader_test.dart; git commit -m ''feat(novel): constrain reader text and input'''
```

## Task 7: Build Immersive Chrome and Whole-Book Seeking

**Files:**
- Create: `lib/features/novel/novel_reader_chrome.dart`
- Modify: `lib/features/novel/novel_reader_page.dart`
- Modify: `test/novel_reader_test.dart`

- [ ] **Step 1: Write failing immersive-control tests**

Update the harness to expose the fake controller and store. Add tests for hidden initial chrome, command-based reveal, timeout disabled/enabled, and progress commit:

```dart
testWidgets('reader starts immersive and center command reveals chrome',
    (tester) async {
  final controller = _FakeController();
  await tester.pumpWidget(await _readerHarness(controller));
  await tester.pumpAndSettle();

  expect(find.byKey(const Key('novel-reader-bottom-bar')), findsNothing);
  controller.onCommand!(NovelReaderCommand.toggleControls);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('novel-reader-bottom-bar')), findsOneWidget);
});
```

For timeout, set `toolbarAutoHideSeconds: 1`, reveal controls, pump `999ms` and expect visible, then pump `2ms` and expect hidden. Set `0` in a separate test and pump one minute; controls remain visible. Add a slider test that calls `onChangeEnd(.75)` and verifies one chapter load plus locator restoration.

- [ ] **Step 2: Run reader tests and verify immersive/progress failures**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_reader_test.dart --reporter compact'
```

Expected: FAIL because controls start visible, no timer setting is consumed, and no whole-book slider exists.

- [ ] **Step 3: Create the presentational reader chrome**

Define a single widget with explicit state and callbacks:

```dart
class NovelReaderChrome extends StatelessWidget {
  const NovelReaderChrome({
    super.key,
    required this.visible,
    required this.bookTitle,
    required this.chapterTitle,
    required this.progress,
    required this.previewLabel,
    required this.onBack,
    required this.onDirectory,
    required this.onTheme,
    required this.onSettings,
    required this.onProgressChanged,
    required this.onProgressChangeEnd,
    required this.onInteraction,
  });

  final bool visible;
  final String bookTitle;
  final String chapterTitle;
  final double progress;
  final String previewLabel;
  final VoidCallback onBack;
  final VoidCallback onDirectory;
  final VoidCallback onTheme;
  final VoidCallback onSettings;
  final ValueChanged<double> onProgressChanged;
  final ValueChanged<double> onProgressChangeEnd;
  final VoidCallback onInteraction;
}
```

Use `AnimatedSlide` plus `AnimatedOpacity`, a top bar with back/title only, and a bottom bar keyed `novel-reader-bottom-bar` with directory, slider/percentage, theme swatch button, and text-settings button. Keep controls stable at mobile and desktop widths and use icon tooltips.

- [ ] **Step 4: Add timer ownership and panel pause to `NovelReaderPage`**

Initialize `_showControls = false` and store a nullable timer:

```dart
Timer? _controlsTimer;
bool _controlsPaused = false;

void _showReaderControls() {
  _controlsTimer?.cancel();
  if (mounted) setState(() => _showControls = true);
  _scheduleControlsHide();
}

void _scheduleControlsHide() {
  _controlsTimer?.cancel();
  final seconds = _preferences.toolbarAutoHideSeconds;
  if (!_showControls || _controlsPaused || seconds == 0) return;
  _controlsTimer = Timer(Duration(seconds: seconds), () {
    if (mounted && !_controlsPaused) setState(() => _showControls = false);
  });
}
```

Set `_controlsPaused = true` before opening directory, theme, or settings, and restore it in `finally`. Cancel the timer in `dispose`. Toggle commands show/hide deliberately; every control interaction reschedules the timer. After successful next/previous page, hide controls.

- [ ] **Step 5: Integrate whole-book preview and one-shot seek**

Track the latest chapter fraction from `_saveLocator` and a nullable preview value:

```dart
double _chapterFraction = 0;
double? _progressPreview;

double get _bookProgress => novelBookProgress(
  chapterIndex: _chapterIndex,
  chapterFraction: _chapterFraction,
  chapterCount: widget.chapters.length,
);
```

`onProgressChanged` only updates `_progressPreview`. `onProgressChangeEnd` computes one `NovelProgressTarget`, loads the target chapter once, restores `NovelLocator(chapterId: target.id, fraction: target.chapterFraction)`, and clears preview. If loading fails, restore the previous chapter index, locator, and displayed progress; do not call `saveProgress` with the failed target.

- [ ] **Step 6: Preserve and refine keyboard behavior**

Keep current page keys. Change `Escape` priority to close/pause overlays, then hide visible controls, then return ignored so normal navigation can handle it. Ensure focus returns to the reader after a panel closes.

- [ ] **Step 7: Run all novel reader and sync tests**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\novel_reader_test.dart test\novel_book_progress_test.dart test\novel_library_store_test.dart test\novel_sync_test.dart --reporter compact'
```

Expected: all immersive, timing, seeking, persistence, locator, and sync tests pass.

- [ ] **Step 8: Commit immersive reader chrome**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add -- lib/features/novel/novel_reader_chrome.dart lib/features/novel/novel_reader_page.dart test/novel_reader_test.dart; git commit -m ''feat(novel): add immersive reading chrome'''
```

## Task 8: Final Regression and Scope Audit

**Files:**
- No source changes are expected in this task. A failure returns to the task that owns the affected file, where its focused test must pass again before resuming this audit.

- [ ] **Step 1: Regenerate ignored localization output**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter gen-l10n'
```

Expected: generated localization files contain the new keys and remain ignored by Git.

- [ ] **Step 2: Run static analysis**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter analyze'
```

Expected: `No issues found!`

- [ ] **Step 3: Run the complete test suite with the current QuickJS DLL**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; $config = Get-Content -LiteralPath ''.dart_tool\package_config.json'' -Raw -Encoding UTF8 | ConvertFrom-Json; $package = $config.packages | Where-Object { $_.name -eq ''flutter_js'' } | Select-Object -First 1; if (-not $package) { throw ''flutter_js missing from package_config.json'' }; $dllDir = Join-Path ([System.Uri]::new($package.rootUri).LocalPath) ''windows\shared''; if (-not (Test-Path -LiteralPath (Join-Path $dllDir ''quickjs_c_bridge.dll''))) { throw ''QuickJS DLL missing'' }; $env:PATH = $dllDir + [System.IO.Path]::PathSeparator + $env:PATH; flutter test --reporter compact'
```

Expected: every test in the current upstream-based branch passes.

- [ ] **Step 4: Audit exact branch scope**

```powershell
& 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe' -NoProfile -Command '$ErrorActionPreference = ''Stop''; git status -sb; git diff --check upstream/main..HEAD; git diff --name-status upstream/main..HEAD; git log --oneline upstream/main..HEAD'
```

Expected: only the design/plan, novel/source-health implementation, localization sources, and tests are present. No generated localization files, build output, source scripts, or release files are tracked.

## Completion Criteria

- Qidian-shaped novel metadata passes health detection through `NovelSource`.
- Novel discovery uses the exact global manga feed layout selection.
- Novel details have manga-style narrow/wide composition and a lazy novel directory.
- Reader starts immersive with a centered single-page body capped near `760px` on Windows.
- Bottom controls expose directory, whole-book progress, theme, and typography.
- Auto-hide is globally configurable from `0` to `10` seconds, defaults to `4`, and pauses for open panels.
- All existing novel import, cache, download, progress, sync, manga, anime, update, and source tests pass.
- `flutter analyze` is clean and no platform package build was run.
