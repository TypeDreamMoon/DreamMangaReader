# Legacy Download Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import complete manga and novel downloads into the unified task index without moving, deleting, or redownloading existing files.

**Architecture:** `LegacyDownloadMigrator` converts public legacy-store records into completed `DownloadTask` records. `DownloadCoordinator.importCompleted` atomically inserts only missing task IDs, making startup migration idempotent while the old stores remain the source of truth for offline reading during the compatibility release.

**Tech Stack:** Dart, Flutter, SharedPreferences-backed legacy stores, atomic JSON task repository.

**Deferred verification:** The user requested that long-running Flutter tests and platform builds be grouped with later features. Test cases are added with each behavior, but execution is deferred to the consolidated verification stage.

---

## File Map

- Modify `lib/core/downloads/download_coordinator.dart`: atomically import completed records without scheduling them.
- Create `lib/app/legacy_download_migrator.dart`: stable legacy IDs and manga/novel record conversion.
- Modify `lib/app/app.dart`: wait for the three download stores, then run migration.
- Modify `test/download_coordinator_test.dart`: cover idempotent completed imports.
- Create `test/legacy_download_migrator_test.dart`: cover record mapping and no-file-move behavior.

### Task 1: Atomic Completed-Task Import

- [ ] Add a coordinator test asserting that `importCompleted` accepts completed tasks, skips an existing ID, persists once, and never starts an executor.

```dart
await coordinator.importCompleted([completedTask, duplicateTask]);
expect(coordinator.task(completedTask.id), completedTask);
expect(repository.saved, hasLength(1));
```

- [ ] Add `Future<void> importCompleted(Iterable<DownloadTask> tasks)` to `DownloadCoordinator`. Reject non-completed input, merge missing IDs in one serialized mutation, and avoid repository writes when nothing changes.

- [ ] Format changed files and run `git diff --check`. Defer Flutter test execution.

- [ ] Commit as `feat(downloads): import completed legacy tasks`.

### Task 2: Legacy Record Conversion

- [ ] Add tests that convert one `DownloadedChapter` and one `DownloadedNovelChapter` into completed tasks while preserving source/content IDs, local directory, resource count, byte count, and completion time.

```dart
final tasks = LegacyDownloadMigrator.buildTasks(
  manga: [downloadedMangaChapter],
  novels: [downloadedNovelChapter],
);
expect(tasks.map((task) => task.kind),
    containsAll([DownloadContentKind.manga, DownloadContentKind.novel]));
```

- [ ] Implement `LegacyDownloadMigrator.buildTasks`. Encode the identity tuple with UTF-8 JSON and URL-safe Base64 so source IDs containing punctuation cannot collide. Store only stable identifiers, local paths, and counts in payload; do not store source URLs, headers, cookies, or tokens.

- [ ] Implement `migrate` by flattening `DownloadStore.byManga` and `NovelDownloadStore.downloads`, then calling `coordinator.importCompleted` once. Do not mutate either legacy store or any content file.

- [ ] Format and inspect the diff. Defer Flutter test execution.

- [ ] Commit as `feat(downloads): map legacy offline records`.

### Task 3: Startup Migration

- [ ] Add an app-level test fixture showing migration starts only after the coordinator and both legacy stores finish loading.

- [ ] In `App.initState`, replace independent download load calls with one `Future.wait`, then invoke `LegacyDownloadMigrator.migrate`. Log migration failure without deleting legacy state or preventing app startup.

```dart
unawaited(Future.wait([
  _downloadCoordinator.load(),
  _downloads.load(),
  _novelDownloads.load(),
]).then((_) => LegacyDownloadMigrator.migrate(...)));
```

- [ ] Format, run `git diff --check`, and inspect `git status --short`. Defer full tests and platform builds.

- [ ] Commit as `feat(downloads): migrate offline records at startup`.

### Task 4: Consolidated Verification Boundary

- [ ] During the later consolidated verification stage, run focused migration tests, then `flutter analyze`, `flutter test`, Android real-device migration checks, and Windows migration checks.

- [ ] Confirm old indexes and files still exist after migration, repeated startup does not duplicate tasks, and offline reading still resolves the old local files.
