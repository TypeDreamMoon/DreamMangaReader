# Anime Offline Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable VOD anime episode downloads that remain playable without contacting the source.

**Architecture:** Anime tasks carry only stable source, title, and episode identifiers. `AnimeDownloadStore` resolves fresh tracks at execution time, selects a fixed smart-quality HLS variant, downloads its playlist resources into a private non-evicting directory, and publishes an atomic local index only after verification. Playback and the completed-download view consume that index; the existing online HLS cache remains independent.

**Tech Stack:** Flutter/Dart, `package:hls`, Dio through `HlsUpstreamClient`, existing durable download coordinator, `path_provider`, JSON index files.

---

### Task 1: Define durable anime tasks

**Files:**
- Modify: `lib/core/downloads/content_download_task.dart`
- Test: `test/content_download_task_test.dart`

- [ ] Add a failing test proving `ContentDownloadTask.anime` creates a stable `DownloadContentKind.anime` task without URLs, headers, tokens, or cookies.
- [ ] Run `flutter test test/content_download_task_test.dart` and confirm the missing factory fails.
- [ ] Add `anime(...)`, allow anime in `ContentDownloadRequest.fromTask`, and allow anime IDs in `contentDownloadTaskId`.
- [ ] Re-run the focused test and commit the passing change.

### Task 2: Download one self-contained VOD HLS episode

**Files:**
- Create: `lib/app/anime_download_store.dart`
- Create: `test/anime_download_store_test.dart`
- Use fixtures: `test/fixtures/hls/master.m3u8`, `test/fixtures/hls/media-ts.m3u8`, `test/fixtures/hls/media-fmp4.m3u8`

- [ ] Write failing tests for smart variant selection, VOD-only rejection, TS segments, fMP4 init segments, byte ranges, AES-128 keys, resumable existing files, cancellation, and local manifests containing no upstream URL or request header.
- [ ] Run `flutter test test/anime_download_store_test.dart` and confirm failures are caused by the missing store.
- [ ] Implement `DownloadedAnimeEpisode`, atomic `index.json`, a source/track resolver injected for tests, a private root provider, `.download` temporary files, byte-range requests, resource verification, and relative local manifest rewriting.
- [ ] Re-run the focused test, format the touched files, and commit.

### Task 3: Register the anime executor in the app

**Files:**
- Modify: `lib/app/app.dart`
- Test: `test/app_download_scope_test.dart`

- [ ] Write a failing widget test proving the app exposes the loaded anime store and registers its executor before coordinator scheduling starts.
- [ ] Run the focused test and confirm the missing scope fails.
- [ ] Create/load/dispose `AnimeDownloadStore`, register it with the executor registry, and add `AnimeDownloadScope` beside the existing manga and novel scopes.
- [ ] Re-run the focused test and commit.

### Task 4: Add episode and batch download controls

**Files:**
- Modify: `lib/features/anime/anime_detail_page.dart`
- Test: `test/anime_detail_download_test.dart`

- [ ] Write failing widget tests for per-episode enqueue, completed state, active state, retry state, and download-all confirmation that skips completed episodes.
- [ ] Run the focused test and confirm the controls are absent.
- [ ] Add compact download icons to episode items and a download-all action using `DownloadCoordinatorScope`; preserve the current episode grid and playback tap target.
- [ ] Re-run the focused test and commit.

### Task 5: Prefer complete offline episodes during playback

**Files:**
- Modify: `lib/features/anime/anime_player_page.dart`
- Test: `test/anime_player_page_test.dart`

- [ ] Write a failing test proving a complete local manifest is opened without invoking `source.getVideo`, while an absent download keeps the online resolver path.
- [ ] Run the focused test and confirm online resolution is still called.
- [ ] Build a local HLS `VideoTrack` from `AnimeDownloadStore` before constructing the existing online playback resolver.
- [ ] Re-run the focused player tests and commit.

### Task 6: Show completed anime downloads

**Files:**
- Modify: `lib/features/downloads/downloads_page.dart`
- Test: `test/anime_downloads_view_test.dart`

- [ ] Write a failing widget test that groups completed episodes by anime and opens the selected episode offline.
- [ ] Run the focused test and confirm the anime completed page is empty.
- [ ] Replace the anime placeholder with an `AnimeDownloadStore` backed list matching manga/novel download-page conventions.
- [ ] Re-run the focused test and commit.

### Task 7: Short integration verification

**Files:**
- Verify all files changed above.

- [ ] Run the six focused tests only.
- [ ] Run `dart analyze` on the touched production and test files.
- [ ] Run `git diff --check` and inspect `git status --short`.
- [ ] Do not run full Flutter analysis, platform builds, packaging, or device tests until the later combined validation stage requested by the user.
