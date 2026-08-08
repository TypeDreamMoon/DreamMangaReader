# Novel Reader Experience Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace browser-controlled novel paging with a cross-platform, cached, gesture-driven reader and add the approved typography, themes, bookmarks, annotations, notes, search, backup, and sync behavior.

**Architecture:** Keep the existing WebView as the compatibility renderer for TXT/EPUB/HTML, but expose semantic page metrics and page screenshots through a focused renderer interface. A pure-Dart turn state machine and bounded page cache drive Flutter page surfaces; reader tools use semantic text anchors so they survive reflow and synchronize independently of copyrighted book content.

**Tech Stack:** Flutter/Dart, `flutter_inappwebview`, Flutter fragment shaders and canvas fallback, `SharedPreferences` for global preferences, atomic JSON files for per-book reader data, isolates for full-text indexing, existing WebDAV/Hertz sync backends.

---

## Execution Rules

- Start execution from the approved design commit `eb557aa` in an isolated worktree created with `superpowers:using-git-worktrees`.
- Use a feature branch named `codex/novel-reader-overhaul`.
- Do not copy fonts, images, shaders, or source code from the analyzed iReader APK.
- Do not add a release/package build. Use focused tests throughout, `flutter analyze` at checkpoints, and debug runs for Android/Windows manual verification.
- Run every command through dynamically resolved PowerShell 7. The examples below assume the repository path is `D:\UnrealMap\DreamMangaReader-reader-overhaul`.

## File Map

### Core reader and rendering

- Create `lib/core/novel/reader/novel_reader_models.dart`: semantic anchors, page keys, frame metadata, viewport and selection models.
- Create `lib/core/novel/reader/novel_page_cache.dart`: memory-budgeted LRU page-frame cache.
- Create `lib/core/novel/reader/novel_page_turn_physics.dart`: platform-neutral threshold and duration calculations.
- Create `lib/core/novel/reader/novel_page_turn_controller.dart`: turn state machine and queued discrete command.
- Modify `lib/features/novel/novel_document_view.dart`: WebView metrics, semantic anchors, selection bridge, page positioning and screenshot capture.
- Create `lib/features/novel/novel_page_turn_surface.dart`: five page-turn presentations and texture lifecycle.
- Create `lib/features/novel/novel_reader_input.dart`: touch, mouse, wheel and keyboard normalization.
- Modify `lib/features/novel/novel_reader_page.dart`: orchestration only; no page-turn math.

### Appearance and controls

- Create `lib/core/novel/reader/novel_reader_theme.dart`: theme/background/text configuration.
- Create `lib/core/novel/reader/novel_font_store.dart`: licensed built-in font registry and imported-font storage.
- Create `lib/core/novel/reader/novel_background_store.dart`: custom backgrounds and deterministic project-owned paper textures.
- Modify `lib/app/novel_library_store.dart`: preferences schema v2 and backward migration.
- Modify `lib/features/novel/novel_reader_settings_sheet.dart`: quick and advanced settings.
- Modify `lib/features/novel/novel_reader_chrome.dart`: approved top/bottom controls and status display.

### Reader tools and persistence

- Create `lib/core/novel/reader/novel_reader_data.dart`: bookmark, annotation, note and tombstone models.
- Create `lib/core/novel/reader/novel_reader_data_store.dart`: atomic per-book persistence and item-level merge.
- Create `lib/core/novel/reader/novel_search_index.dart`: cancellable local chapter index and streamed results.
- Create `lib/features/novel/novel_reader_tools_sheet.dart`: directory/bookmark/note tabs.
- Create `lib/features/novel/novel_reader_selection_bar.dart`: copy, highlight, note and in-book search actions.
- Create `lib/features/novel/novel_reader_search_sheet.dart`: incremental search progress and results.
- Modify `lib/core/sync/sync_data.dart`: reader-data category export, merge and apply.
- Modify `lib/app/backup.dart`: portable reader data without text, index, paths or user asset bytes.

### Assets, localization, tests and records

- Create `assets/shaders/novel_page_curl.frag`: project-owned page-curl shader.
- Create `assets/fonts/LXGWWenKai-Regular.ttf`: bundled OFL Chinese reading font from the official LXGW release.
- Create `assets/fonts/NotoSerifSC-Regular.otf`: bundled OFL Chinese serif font from the official Noto release.
- Create `assets/fonts/OFL-LXGW.txt`: LXGW license text.
- Create `assets/fonts/OFL-Noto.txt`: Noto license text.
- Create `assets/fonts/README.md`: font source, release, license and checksum record.
- Modify `pubspec.yaml`: declare shader and legally distributable built-in fonts.
- Modify `lib/l10n/app_zh.arb`, `app_zh_Hant.arb`, `app_en.arb`, `app_ja.arb`: all reader strings.
- Add focused tests listed in each task.
- Create `docs/testing/novel-reader-overhaul.md`: automated results, iReader timing measurements and platform matrix.

## Checkpoint A: Cached Page-Turn Core

### Task 1: Add stable reader models and migrate preferences

**Files:**
- Create: `lib/core/novel/reader/novel_reader_models.dart`
- Modify: `lib/core/novel/models.dart`
- Modify: `lib/app/novel_library_store.dart`
- Test: `test/novel_reader_preferences_test.dart`
- Test: `test/novel_locator_test.dart`

- [ ] **Step 1: Write failing round-trip and migration tests**

Test that old `{mode: paged, theme: sepia}` data migrates to `turnMode: curl`, preserves current values, and supplies defaults for top/bottom margins, first-line indent, alignment, status visibility and single-hand mode. Test that `NovelLocator` round-trips optional `blockId`, `charOffset`, `quote`, `prefix` and `suffix` without changing legacy locators.

```dart
expect(NovelReaderPreferences.fromJson({'mode': 'paged'}).turnMode,
    NovelPageTurnMode.curl);
expect(NovelReaderPreferences.fromJson({'mode': 'scroll'}).turnMode,
    NovelPageTurnMode.scroll);
const anchor = NovelLocator(
  chapterId: 'c1', blockId: 'p7', charOffset: 12,
  quote: '目标文字', prefix: '前文', suffix: '后文', fraction: .4,
);
expect(NovelLocator.fromJson(anchor.toJson()).charOffset, 12);
```

- [ ] **Step 2: Run the focused tests and verify the new API is missing**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_reader_preferences_test.dart test/novel_locator_test.dart'
```

Expected: compilation fails because `NovelPageTurnMode`, semantic locator fields and JSON methods do not exist.

- [ ] **Step 3: Add the models and backward-compatible migration**

Define `NovelPageTurnMode { curl, cover, translate, none, scroll }`, `NovelTextAlignment { start, justify }`, `NovelViewport`, `NovelPageKey`, `NovelPageMetrics`, `NovelPageFrame`, `NovelSelection`, and `NovelReaderCommand`. Keep old JSON keys readable but only write schema-v2 keys. Clamp all numeric preferences in `fromJson`.

```dart
enum NovelPageTurnMode { curl, cover, translate, none, scroll }

class NovelPageKey {
  const NovelPageKey({
    required this.chapterId,
    required this.pageIndex,
    required this.layoutFingerprint,
  });
  final String chapterId;
  final int pageIndex;
  final String layoutFingerprint;
}
```

- [ ] **Step 4: Run tests and commit**

Run the Step 2 command. Expected: both files pass.

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; git add lib/core/novel/reader/novel_reader_models.dart lib/core/novel/models.dart lib/app/novel_library_store.dart test/novel_reader_preferences_test.dart test/novel_locator_test.dart; git commit -m ''feat(novel): define reader paging models'''
```

### Task 2: Build and test page-turn physics

**Files:**
- Create: `lib/core/novel/reader/novel_page_turn_physics.dart`
- Create: `lib/core/novel/reader/novel_page_turn_controller.dart`
- Test: `test/novel_page_turn_controller_test.dart`

- [ ] **Step 1: Write failing state-machine tests**

Cover horizontal direction locking, vertical rejection, 28% distance commit, fast-fling commit, short-drag rollback, pointer cancel, one queued discrete command, and committing the locator only after settlement.

```dart
controller.begin(const Offset(900, 500), const Size(1000, 1600));
controller.update(const Offset(600, 505), elapsed: const Duration(milliseconds: 180));
expect(controller.state.phase, NovelTurnPhase.dragging);
expect(controller.end(velocity: const Offset(-200, 0)).commit, isTrue);
```

- [ ] **Step 2: Verify failure, then implement pure-Dart physics**

Run:

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_page_turn_controller_test.dart'
```

Expected before implementation: missing controller classes. Implement configurable touch slop, axis dominance, distance/velocity commit and distance-aware settlement duration. The controller must not import WebView or library stores.

- [ ] **Step 3: Run the test and commit**

Expected: all state-machine tests pass.

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; git add lib/core/novel/reader/novel_page_turn_physics.dart lib/core/novel/reader/novel_page_turn_controller.dart test/novel_page_turn_controller_test.dart; git commit -m ''feat(novel): add deterministic page turn state machine'''
```

### Task 3: Add bounded page-frame caching

**Files:**
- Create: `lib/core/novel/reader/novel_page_cache.dart`
- Test: `test/novel_page_cache_test.dart`

- [ ] **Step 1: Write failing tests for a three-page window and memory pressure**

Use fake frame payloads with explicit byte sizes. Verify previous/current/next retention, LRU eviction, current-page pinning, layout-fingerprint invalidation and `shrinkForMemoryPressure()`.

- [ ] **Step 2: Implement `NovelPageCache`**

Use `LinkedHashMap<NovelPageKey, NovelPageFrame>` and a configurable byte budget. `put`, `get`, `pinCurrent`, `invalidateLayout` and `shrinkForMemoryPressure` must be synchronous; frame capture stays outside this class.

- [ ] **Step 3: Run and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_page_cache_test.dart; git add lib/core/novel/reader/novel_page_cache.dart test/novel_page_cache_test.dart; git commit -m ''feat(novel): cache adjacent page frames'''
```

Expected: tests pass and current frame survives every eviction path.

### Task 4: Expose semantic pagination and frame capture from WebView

**Files:**
- Modify: `lib/features/novel/novel_document_view.dart`
- Test: `test/novel_document_pagination_test.dart`
- Test: `integration_test/novel_page_capture_test.dart`

- [ ] **Step 1: Add failing bridge-contract tests**

Test generated bridge script for `__dmrMetrics`, `__dmrShowPage`, `__dmrCaptureAnchor`, `__dmrRestoreAnchor` and `__dmrSelection`. Test page clamping and anchor JSON parsing independently of a platform WebView.

- [ ] **Step 2: Extend `NovelDocumentController`**

Add exact methods:

```dart
Future<NovelPageMetrics> pageMetrics();
Future<NovelPageFrame?> capturePage(int pageIndex);
Future<void> showPage(int pageIndex);
ValueChanged<NovelSelection?>? onSelectionChanged;
```

`capturePage` calls `showPage`, waits for two animation frames, invokes `InAppWebViewController.takeScreenshot()`, then restores the visible page. During capture, the Flutter layer must be able to cover the WebView with the already cached current frame.

- [ ] **Step 3: Add semantic DOM mapping**

Assign stable block IDs during document sanitization. Convert DOM ranges to chapter/block/character anchors, retain at most 32 characters of prefix and suffix, and restore by block/offset before quote-based fallback. Do not include full chapter text in bridge events.

- [ ] **Step 4: Run bridge tests, then platform capture tests**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_document_pagination_test.dart'
```

Expected: unit tests pass. Run `integration_test/novel_page_capture_test.dart` once on Android and once on Windows during Checkpoint A manual verification; it must return non-empty PNG bytes and restore the original page.

- [ ] **Step 5: Commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; git add lib/features/novel/novel_document_view.dart test/novel_document_pagination_test.dart integration_test/novel_page_capture_test.dart; git commit -m ''feat(novel): capture semantic webview pages'''
```

### Task 5: Render all five turn modes

**Files:**
- Create: `assets/shaders/novel_page_curl.frag`
- Create: `lib/features/novel/novel_page_turn_surface.dart`
- Modify: `pubspec.yaml`
- Test: `test/novel_page_turn_surface_test.dart`

- [ ] **Step 1: Write failing widget tests**

Inject fake previous/current/next frames and assert that curl, cover, translate, none and scroll select distinct render paths, settlement calls `onCommitted` once, rollback does not call it, and missing target frames keep the current page visible.

- [ ] **Step 2: Implement cover, translate, none and scroll paths**

Use `Transform.translate` and clipped page layers. Pre-resolve `MemoryImage` providers before entering `dragging`; do not decode PNGs inside `paint`.

- [ ] **Step 3: Implement the project-owned curl shader and canvas fallback**

The shader accepts viewport size, normalized drag point, direction, current texture and target texture. Clamp the fold radius, shade the page back with the active theme color, and draw a soft contact shadow. The fallback uses clipped transforms and a shadowed fold strip so unsupported devices still remain interactive.

- [ ] **Step 4: Run tests and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_page_turn_surface_test.dart; git add assets/shaders/novel_page_curl.frag lib/features/novel/novel_page_turn_surface.dart pubspec.yaml test/novel_page_turn_surface_test.dart; git commit -m ''feat(novel): render five page turn modes'''
```

### Task 6: Integrate input, cache and reader orchestration

**Files:**
- Create: `lib/features/novel/novel_reader_input.dart`
- Modify: `lib/features/novel/novel_reader_page.dart`
- Modify: `test/novel_reader_test.dart`
- Create: `test/novel_reader_input_test.dart`

- [ ] **Step 1: Add failing input and reader integration tests**

Cover Android pointer drag, Windows mouse drag, wheel throttling, keyboard paging, center tap chrome, 25/50/25 zones, single-hand zones, chapter-boundary prefetch, loading-edge retention and progress saved after commit only.

- [ ] **Step 2: Implement `NovelReaderInput`**

Use `Listener`, `GestureDetector`, `Focus` and `Shortcuts/Actions`. Convert events to controller commands and ignore them while selection, chrome sheets or note editing are active.

- [ ] **Step 3: Reduce `NovelReaderPage` to orchestration**

Move page math into the controller, frame retention into the cache and drawing into the surface. `NovelReaderPage` loads documents, owns the current semantic locator, prefetches adjacent frames, and saves progress only from the surface commit callback.

- [ ] **Step 4: Run Checkpoint A tests and analyze**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_reader_input_test.dart test/novel_reader_test.dart test/novel_page_turn_controller_test.dart test/novel_page_cache_test.dart test/novel_document_pagination_test.dart test/novel_page_turn_surface_test.dart; flutter analyze'
```

Expected: focused tests pass and analyzer reports no issues.

- [ ] **Step 5: Commit Checkpoint A**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; git add lib/features/novel/novel_reader_input.dart lib/features/novel/novel_reader_page.dart test/novel_reader_input_test.dart test/novel_reader_test.dart; git commit -m ''feat(novel): integrate cached gesture paging'''
```

## Checkpoint B: Typography, Themes and Chrome

### Task 7: Add complete typography and settings migration

**Files:**
- Modify: `lib/app/novel_library_store.dart`
- Modify: `lib/features/novel/novel_document_view.dart`
- Modify: `lib/features/novel/novel_reader_settings_sheet.dart`
- Test: `test/novel_reader_preferences_test.dart`
- Test: `test/novel_reader_settings_test.dart`

- [ ] **Step 1: Add failing preference clamp and UI tests**

Cover line/paragraph spacing, four margins, first-line indent, start/justify alignment, five turn modes, status toggles, reset, rapid changes preserving semantic anchors and the legacy migration from Task 1.

- [ ] **Step 2: Implement quick and advanced settings**

Quick controls contain font size, font, background, brightness and turn mode. Advanced controls contain line spacing, paragraph spacing, top/bottom/side margins, first-line indent, alignment, status items, single-hand mode, keep-awake and toolbar auto-hide.

- [ ] **Step 3: Apply CSS without negative letter spacing**

Generate CSS variables for every setting. Keep `letter-spacing: 0`, use `text-indent` in em, and apply `text-align: justify` only when selected. Reflow through capture-anchor, apply, two-frame wait, restore-anchor.

- [ ] **Step 4: Run and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_reader_preferences_test.dart test/novel_reader_settings_test.dart test/novel_reader_test.dart; git add lib/app/novel_library_store.dart lib/features/novel/novel_document_view.dart lib/features/novel/novel_reader_settings_sheet.dart test/novel_reader_preferences_test.dart test/novel_reader_settings_test.dart test/novel_reader_test.dart; git commit -m ''feat(novel): expand reader typography controls'''
```

### Task 8: Add licensed fonts and resilient font import

**Files:**
- Create: `lib/core/novel/reader/novel_font_store.dart`
- Create: `assets/fonts/LXGWWenKai-Regular.ttf`
- Create: `assets/fonts/NotoSerifSC-Regular.otf`
- Create: `assets/fonts/OFL-LXGW.txt`
- Create: `assets/fonts/OFL-Noto.txt`
- Create: `assets/fonts/README.md`
- Modify: `pubspec.yaml`
- Modify: `lib/features/novel/novel_reader_settings_sheet.dart`
- Test: `test/novel_font_store_test.dart`

- [ ] **Step 1: Write failing import tests**

Use test fixtures for a valid font header, truncated file, unsupported extension and duplicate hash. Verify imports are copied under application support, names are sanitized, duplicate files are reused, deletion falls back to the built-in serif family, and font bytes never appear in preference JSON.

- [ ] **Step 2: Add two OFL-licensed Chinese reading fonts**

Use official upstream releases for LXGW WenKai and Noto Serif SC. Record upstream URL, release version, license path and SHA-256 for each exact bundled file in `assets/fonts/README.md`; keep their OFL license texts beside the font files. Do not source files from the APK.

- [ ] **Step 3: Implement import and WebView `@font-face` registration**

Validate TTF/OTF signatures before copying. Register built-in and imported fonts with file URLs allowed by the existing CSP. If page metrics report zero visible text after a font change, restore the previous family and show a recoverable error.

- [ ] **Step 4: Run and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_font_store_test.dart test/novel_reader_settings_test.dart; git add lib/core/novel/reader/novel_font_store.dart assets/fonts pubspec.yaml lib/features/novel/novel_reader_settings_sheet.dart test/novel_font_store_test.dart test/novel_reader_settings_test.dart; git commit -m ''feat(novel): add resilient reader fonts'''
```

### Task 9: Add paper themes and custom backgrounds

**Files:**
- Create: `lib/core/novel/reader/novel_reader_theme.dart`
- Create: `lib/core/novel/reader/novel_background_store.dart`
- Modify: `lib/features/novel/novel_reader_settings_sheet.dart`
- Modify: `lib/features/novel/novel_document_view.dart`
- Test: `test/novel_reader_theme_test.dart`
- Test: `test/novel_background_store_test.dart`

- [ ] **Step 1: Write failing theme and file-safety tests**

Verify white, eye-care, dark, black and paper themes; readable automatic foreground selection; custom foreground override; crop/tile/fill modes; deterministic texture generation; missing/corrupt file fallback; and no image bytes in exported sync data.

- [ ] **Step 2: Implement project-owned paper textures**

Generate small deterministic bitmap tiles from seeded paper fibers and low-amplitude noise, cache them under application support, and keep contrast low enough for body text. Do not use gradients or extracted textures.

- [ ] **Step 3: Implement custom image storage and theme profiles**

Copy selected images into a reader-background directory, validate decode before activation, store only the local asset ID in preferences, and delete unreferenced files. Apply foreground, system-bar and chrome contrast from the active theme.

- [ ] **Step 4: Run and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_reader_theme_test.dart test/novel_background_store_test.dart test/novel_reader_settings_test.dart; git add lib/core/novel/reader/novel_reader_theme.dart lib/core/novel/reader/novel_background_store.dart lib/features/novel/novel_reader_settings_sheet.dart lib/features/novel/novel_document_view.dart test/novel_reader_theme_test.dart test/novel_background_store_test.dart; git commit -m ''feat(novel): add paper and custom reader themes'''
```

### Task 10: Rebuild reader chrome and status overlay

**Files:**
- Modify: `lib/features/novel/novel_reader_chrome.dart`
- Modify: `lib/features/novel/novel_reader_page.dart`
- Test: `test/novel_reader_chrome_test.dart`

- [ ] **Step 1: Write failing layout tests at 360x800, 800x1280 and 1280x720**

Assert top/bottom chrome overlays without changing page viewport, all text fits, secondary commands move into overflow on narrow landscape, auto-hide pauses while a sheet is open, and chapter/page/progress/time/battery toggles alter only the status overlay.

- [ ] **Step 2: Implement approved chrome**

Top: back, title/chapter, bookmark, overflow. Bottom: previous chapter, whole-book progress, next chapter, directory, search, theme and typography. Use fixed dimensions, short slide/fade transitions and theme-derived scrims.

- [ ] **Step 3: Run Checkpoint B tests and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_reader_chrome_test.dart test/novel_reader_settings_test.dart test/novel_reader_test.dart; flutter analyze; git add lib/features/novel/novel_reader_chrome.dart lib/features/novel/novel_reader_page.dart test/novel_reader_chrome_test.dart; git commit -m ''feat(novel): rebuild reader chrome and status'''
```

Expected: tests pass and analyzer reports no issues.

## Checkpoint C: Bookmarks, Notes, Search and Sync

### Task 11: Persist bookmark and annotation data atomically

**Files:**
- Create: `lib/core/novel/reader/novel_reader_data.dart`
- Create: `lib/core/novel/reader/novel_reader_data_store.dart`
- Test: `test/novel_reader_data_store_test.dart`

- [ ] **Step 1: Write failing model, atomic-write and merge tests**

Cover stable IDs, quote/prefix/suffix caps, bookmarks, colored highlights, optional note text, per-item `updatedAt`, deletion tombstones, recovery from a leftover temporary file, different-item union and same-item last-write-wins.

- [ ] **Step 2: Implement portable models**

```dart
class NovelAnnotation {
  const NovelAnnotation({
    required this.id,
    required this.bookKey,
    required this.range,
    required this.colorId,
    required this.createdAt,
    required this.updatedAt,
    this.note,
    this.deletedAt,
  });
  // JSON contains only semantic anchors, short quote context and user data.
}
```

- [ ] **Step 3: Implement atomic per-book storage**

Write UTF-8 JSON to `<book-hash>.json.tmp`, flush, then rename over `<book-hash>.json`. On load, validate schema and retain a corrupt copy before starting empty. Use timers for normal writes and an explicit `flushPending()` on lifecycle boundaries.

- [ ] **Step 4: Run and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_reader_data_store_test.dart; git add lib/core/novel/reader/novel_reader_data.dart lib/core/novel/reader/novel_reader_data_store.dart test/novel_reader_data_store_test.dart; git commit -m ''feat(novel): persist bookmarks and annotations'''
```

### Task 12: Add selection, bookmarks, highlights and notes UI

**Files:**
- Modify: `lib/features/novel/novel_document_view.dart`
- Create: `lib/features/novel/novel_reader_selection_bar.dart`
- Create: `lib/features/novel/novel_reader_tools_sheet.dart`
- Modify: `lib/features/novel/novel_reader_chrome.dart`
- Modify: `lib/features/novel/novel_reader_page.dart`
- Test: `test/novel_reader_tools_test.dart`

- [ ] **Step 1: Write failing UI and anchor-recovery tests**

Cover long-press/mouse selection pausing turn input, copy, highlight creation, note editing, highlight deletion, bookmark creation, directory/bookmark/note tabs, reflow reattachment and unresolved-item display.

- [ ] **Step 2: Implement the WebView range bridge**

Emit selection anchors and rectangles through `dmrSelection`. Apply stored annotations as layout-neutral inline marks before page capture. Restore by block/offset, then exact quote within prefix/suffix, and finally mark unresolved without altering data.

- [ ] **Step 3: Implement Flutter tools**

The selection bar contains Copy, Highlight, Note and Search in book. The tools sheet contains Directory, Bookmarks and Notes tabs. Editing sheets set `interactionBlocked=true` on `NovelReaderInput` until dismissed. Reader page disposal, application pause and explicit back navigation call `NovelReaderDataStore.flushPending()` before releasing the store.

- [ ] **Step 4: Run and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_reader_tools_test.dart test/novel_reader_test.dart; git add lib/features/novel/novel_document_view.dart lib/features/novel/novel_reader_selection_bar.dart lib/features/novel/novel_reader_tools_sheet.dart lib/features/novel/novel_reader_chrome.dart lib/features/novel/novel_reader_page.dart test/novel_reader_tools_test.dart; git commit -m ''feat(novel): add bookmarks highlights and notes'''
```

### Task 13: Add cancellable full-text search

**Files:**
- Create: `lib/core/novel/reader/novel_search_index.dart`
- Create: `lib/features/novel/novel_reader_search_sheet.dart`
- Modify: `lib/features/novel/novel_reader_page.dart`
- Test: `test/novel_search_index_test.dart`
- Test: `test/novel_reader_search_sheet_test.dart`

- [ ] **Step 1: Write failing indexing tests**

Use Chinese fixtures to cover substring matches, chapter ordering, context snippets, streamed partial results, cancellation, changed-chapter rebuild, cached-only network search and explicit full-book fetch progress.

- [ ] **Step 2: Implement local chapter index files**

Store normalized plain text per chapter and a small metadata manifest containing source fingerprint and chapter hashes. Build and scan in a worker created with `Isolate.spawn`; return result batches, progress and cancellation acknowledgement through `ReceivePort`, then delete obsolete chapter files on manifest update. Never serialize whole-book text into sync data.

- [ ] **Step 3: Implement the search sheet**

Show query, local/full-book scope, indexing progress, cancel, chapter name and context. Clicking a result constructs a semantic locator, restores it, then applies a temporary non-persistent highlight.

- [ ] **Step 4: Run and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_search_index_test.dart test/novel_reader_search_sheet_test.dart; git add lib/core/novel/reader/novel_search_index.dart lib/features/novel/novel_reader_search_sheet.dart lib/features/novel/novel_reader_page.dart test/novel_search_index_test.dart test/novel_reader_search_sheet_test.dart; git commit -m ''feat(novel): add cancellable full text search'''
```

### Task 14: Extend sync and portable backup without book content

**Files:**
- Modify: `lib/core/sync/sync_data.dart`
- Modify: `lib/app/backup.dart`
- Modify: `lib/features/settings/sync_page.dart`
- Modify: `test/novel_sync_test.dart`
- Modify: `test/novel_backup_test.dart`

- [ ] **Step 1: Write failing category, merge and sanitizer tests**

Add a `readerNotes` sync category. Verify item-level union/LWW/tombstones, category selection, apply modes, and that encoded sync/backup output contains no chapter content, local asset path, font bytes, background bytes, page PNG, search index or source token.

- [ ] **Step 2: Add export/merge/apply integration**

Export portable reader data separately from `history` and `readerSettings`. Merge by book key then item ID. On apply, merge or replace according to the selected mode and flush the reader data store before reporting success.

- [ ] **Step 3: Add the sync-page category control**

Expose “小说书签与笔记” independently from progress and settings. Existing users retain current sync categories; the new category defaults enabled only when their sync configuration already includes novel history.

- [ ] **Step 4: Run and commit**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter test --no-pub test/novel_sync_test.dart test/novel_backup_test.dart test/novel_reader_data_store_test.dart; git add lib/core/sync/sync_data.dart lib/app/backup.dart lib/features/settings/sync_page.dart test/novel_sync_test.dart test/novel_backup_test.dart; git commit -m ''feat(novel): sync portable reader notes'''
```

### Task 15: Localize, validate accessibility and complete regression coverage

**Files:**
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_zh_Hant.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`
- Modify: reader widget tests that currently use temporary literals
- Create: `docs/testing/novel-reader-overhaul.md`

- [ ] **Step 1: Add all localization keys and regenerate**

Include five turn modes, quick/advanced settings, margins, alignment, font/background import errors, status toggles, selection actions, tabs, annotation states, search scopes/progress and sync category. Remove reader-facing hard-coded strings.

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; flutter gen-l10n'
```

- [ ] **Step 2: Add semantics and keyboard assertions**

Ensure icon buttons have localized tooltips/semantics, selected themes and modes announce state, sliders expose values, selection actions are keyboard reachable, and longest Chinese/English labels fit narrow settings layouts.

- [ ] **Step 3: Run the complete automated reader suite**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; $tests=Get-ChildItem -LiteralPath ''test'' -File | Where-Object { $_.Name -match ''^(novel_|epub_|txt_)'' }; if($tests.Count -eq 0){ throw ''reader test set is empty'' }; flutter test --no-pub @($tests.FullName); if($LASTEXITCODE -ne 0){ throw ''reader tests failed'' }; flutter analyze; if($LASTEXITCODE -ne 0){ throw ''flutter analyze failed'' }'
```

Expected: all selected tests pass and analyzer reports no issues.

- [ ] **Step 4: Perform Android and Windows debug validation**

Run on an Android emulator first, then a physical Android device and Windows desktop. Import the four user-provided books locally. Check all five modes, continuous turns, boundaries, rotation/resize, font/background failures, selection, notes, search and lifecycle flush. Record device, refresh rate, frame timing and failures in `docs/testing/novel-reader-overhaul.md`.

- [ ] **Step 5: Measure iReader timing and tune only configuration constants**

On the same Android device and same TXT, record slow drag, fast fling, rollback, tap and repeated tap in iReader 8.7.7 and DreamMangaReader. Document measured frames and tune `NovelPageTurnPhysics` defaults without copying implementation or assets. Rerun Task 2 tests after every constant change.

- [ ] **Step 6: Commit validation and localization**

```powershell
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference=''Stop''; Set-Location ''D:\UnrealMap\DreamMangaReader-reader-overhaul''; git add lib/l10n lib/features/novel lib/core/novel/reader test docs/testing/novel-reader-overhaul.md; git commit -m ''test(novel): validate reader overhaul''; git status --short --branch'
```

Expected: final status is clean. Do not push or open a pull request until the user reviews the validation record.
