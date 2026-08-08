# Native Novel Page Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace WebView-based novel paging with a Flutter-native document, pagination, page-cache, and Canvas rendering pipeline that supports phone single pages and desktop/tablet two-page book spreads.

**Architecture:** Parse TXT and reflowable EPUB HTML into stable semantic blocks, paginate those blocks with Flutter text metrics into immutable page layouts, and render the same layouts both at rest and during page turns. Keep WebView outside the normal reading path; unsupported fixed-layout EPUB remains rejected instead of silently opening a browser renderer.

**Tech Stack:** Flutter `TextPainter`/`Canvas`, package:html, existing reader preferences, semantic `NovelLocator`, widget and unit tests.

---

### Task 1: Semantic document model and parser

**Files:**
- Create: `lib/core/novel/reader/novel_render_document.dart`
- Create: `test/novel_render_document_test.dart`

- [ ] Write failing tests proving TXT blank lines, HTML headings, paragraphs, lists, ruby fallback text, images, stable block IDs, and unsafe elements normalize into semantic blocks.
- [ ] Run `flutter test --no-pub test/novel_render_document_test.dart` and confirm failure because the API does not exist.
- [ ] Implement `NovelRenderDocumentParser.parse(NovelDocument)` with immutable block models and source character offsets.
- [ ] Run the focused test and confirm it passes.

### Task 2: Native pagination and responsive book spreads

**Files:**
- Create: `lib/core/novel/reader/novel_paginator.dart`
- Create: `test/novel_paginator_test.dart`

- [ ] Write failing widget tests for deterministic pagination, no lost/duplicated characters, paragraph spacing, first-line indent, page-boundary restoration, a centered single page below the wide threshold or in portrait, and a two-page book spread in wide landscape viewports.
- [ ] Confirm the tests fail because the paginator does not exist.
- [ ] Implement immutable `NovelPageLayout`, `NovelPageFragment`, `NovelBookSpread`, and `NovelPaginator`; use bounded text measurement and preserve block/character ranges on every fragment.
- [ ] Use readable page widths rather than stretching text: single-page content is width constrained; wide landscape mode has two equal leaves separated by a fixed gutter and portrait remains single-page.
- [ ] Run the focused tests and confirm they pass.

### Task 3: Canvas page surface

**Files:**
- Create: `lib/features/novel/novel_native_page_view.dart`
- Create: `test/novel_native_page_view_test.dart`

- [ ] Write failing golden-independent widget tests that assert one/two page leaves, paper background continuity, gutter placement, visible page numbers, and semantic text labels.
- [ ] Confirm failure before implementation.
- [ ] Implement a `CustomPainter` that paints backgrounds, text fragments, images/placeholders, annotations, page-edge shading, and the center spine from `NovelBookSpread` only.
- [ ] Run the focused tests and confirm they pass.

### Task 4: Atomic reader integration without WebView paging

**Files:**
- Create: `lib/core/novel/reader/novel_native_document_controller.dart`
- Modify: `lib/features/novel/novel_reader_page.dart`
- Modify: `lib/features/novel/novel_document_view.dart`
- Test: `test/novel_reader_test.dart`

- [ ] Write failing integration tests proving the normal TXT/HTML path constructs the native controller, adjacent spreads are ready before input, commit atomically swaps the current spread, resizing restores the same semantic locator, and no `InAppWebView` exists in the reader subtree.
- [ ] Confirm expected failures.
- [ ] Implement native document loading, pagination generation, previous/current/next spread retention, locator capture/restore, and preference-driven repagination.
- [ ] Replace the normal reader body with `NovelNativePageView`; keep the old WebView implementation disconnected temporarily for migration reference.
- [ ] Run focused reader tests and static analysis.

### Task 5: Touch-point page curl and book-leaf rendering

**Files:**
- Modify: `lib/core/novel/reader/novel_page_turn_controller.dart`
- Modify: `lib/features/novel/novel_reader_input.dart`
- Modify: `lib/features/novel/novel_page_turn_surface.dart`
- Modify: `assets/shaders/novel_page_curl.frag`
- Test: `test/novel_page_turn_controller_test.dart`
- Test: `test/novel_page_turn_surface_test.dart`

- [ ] Write failing tests for the exact down position, dragged fold point, top/bottom corner choice, rollback, velocity commit, single-page right/left turns, and two-page right/left leaf turns.
- [ ] Confirm current fade/linear-progress behavior fails the new assertions.
- [ ] Carry pointer origin and live pointer position through `NovelTurnState`; derive fold geometry from those coordinates rather than a scalar fade progress.
- [ ] Render front paper, curled back paper, curved clipping, dynamic contact shadow, spine shadow, and target page continuously; never reveal another renderer beneath it.
- [ ] Run focused page-turn tests and compare slow drag, release, rollback, and rapid taps with iReader on the same device before tuning timing constants.

### Task 6: Migrate reader tools and remove the obsolete path

**Files:**
- Modify: `lib/core/novel/reader/novel_native_document_controller.dart`
- Modify: `lib/features/novel/novel_reader_page.dart`
- Modify: reader search/annotation tests
- Delete after migration: WebView-only paging bridge from `lib/features/novel/novel_document_view.dart`

- [ ] Add failing tests for selection ranges, copy, highlights, notes, search navigation, images, links, bookmarks, chapter boundaries, history progress, and cloud-portable locators.
- [ ] Implement hit testing and selection against page fragments, annotation painting, image layout, and semantic locator navigation.
- [ ] Remove WebView paging only after all migrated behavior passes.
- [ ] Run all `novel_`, `epub_`, and `txt_` tests plus `flutter analyze --no-pub`.
