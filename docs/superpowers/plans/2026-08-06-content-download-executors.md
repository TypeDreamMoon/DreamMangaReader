# Manga And Novel Download Executors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route new manga and novel chapter downloads through `DownloadCoordinator` while preserving the existing offline indexes and readers.

**Architecture:** A safe task factory serializes only stable content identifiers. Manga and novel executors resolve current source metadata at execution time, reuse existing content/cache pipelines, report progress through the coordinator, and commit successful results back to the compatibility stores.

**Tech Stack:** Dart, Flutter, QuickJS source adapters, existing image/document caches.

**Deferred verification:** Long Flutter tests and platform builds are grouped into the later consolidated verification stage at the user's request.

---

### Task 1: Safe Content Task Factory

- [ ] Add tests for stable collision-resistant IDs, secret-free payloads, queued tasks, and completed compatibility records.
- [ ] Create `lib/core/downloads/content_download_task.dart` with manga/novel factories and a strict payload decoder.
- [ ] Make legacy migration use the same factory so old and new records cannot duplicate.
- [ ] Run focused static analysis and commit as `feat(downloads): define content download tasks`.

### Task 2: Manga Executor

- [ ] Add executor tests for ordered pages, progress, cancellation, Base64/local/network images, per-page failure, and completion index writes.
- [ ] Extract a cancellable single-chapter operation from `DownloadStore` without changing its offline lookup format.
- [ ] Implement `MangaDownloadExecutor` and register it after startup migration.
- [ ] Run focused static analysis and commit as `feat(downloads): execute manga chapter tasks`.

### Task 3: Novel Executor

- [ ] Add executor tests for document fetch, sanitized cache writes, resource progress, cancellation, and completion index writes.
- [ ] Extract a cancellable single-chapter operation from `NovelDownloadStore` while preserving local TXT/EPUB behavior.
- [ ] Implement `NovelDownloadExecutor` and register it after startup migration.
- [ ] Run focused static analysis and commit as `feat(downloads): execute novel chapter tasks`.

### Task 4: Switch New Download Entry Points

- [ ] Change manga single/batch actions and novel single/batch actions to enqueue unified tasks.
- [ ] Read progress, failure, pause, retry, and completion from `DownloadCoordinator`, retaining legacy stores only for completed local content during the compatibility release.
- [ ] Keep duplicate actions idempotent by checking the stable task ID before enqueue.
- [ ] Run formatting and diff checks, then commit as `feat(downloads): route content downloads through coordinator`.

### Task 5: Consolidated Verification Boundary

- [ ] Later run focused executor tests, `flutter analyze`, `flutter test`, then Windows and Android offline download checks.
- [ ] Verify cancellation, restart recovery, no credential persistence, old offline reading, and no duplicate migrated records.
