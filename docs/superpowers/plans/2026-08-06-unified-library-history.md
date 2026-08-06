# Unified Library History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manga/novel library switch with one library home containing unified history plus separate manga, novel, and anime favorite sections, including second-accurate anime resume.

**Architecture:** Existing manga and novel stores remain authoritative. A new `AnimeLibraryStore` owns anime favorites/history, while a pure unified-history projector merges all three stores for display. Anime playback reports integer-second progress through the existing playback controller and resumes only after a track has opened.

**Tech Stack:** Flutter/Dart, SharedPreferences, existing `LibraryStore`/`NovelLibraryStore`, media_kit adapter, Flutter widget/unit tests.

---

### Task 1: Persist anime favorites and second-accurate history

**Files:**
- Create: `lib/app/anime_library_store.dart`
- Create: `test/anime_library_store_test.dart`

- [ ] **Step 1: Write failing persistence tests**

Cover favorite toggle/reload, malformed-record repair, integer-second deduplication, ordered history, per-entry removal, clear-all, and `flushPending()`:

```dart
test('anime history persists one record per integer second', () async {
  SharedPreferences.setMockInitialValues(const {});
  final store = AnimeLibraryStore(persistDelay: Duration.zero);
  await store.load();

  store.saveProgress(
    sourceId: 's',
    animeId: 'a',
    title: '番剧',
    episodeId: 'ep-2',
    episodeName: '第二集',
    episodeIndex: 1,
    position: const Duration(milliseconds: 12600),
    duration: const Duration(minutes: 24),
    updatedAt: 30,
  );
  store.saveProgress(
    sourceId: 's',
    animeId: 'a',
    title: '番剧',
    episodeId: 'ep-2',
    episodeName: '第二集',
    episodeIndex: 1,
    position: const Duration(milliseconds: 12900),
    duration: const Duration(minutes: 24),
    updatedAt: 31,
  );
  await store.flushPending();

  expect(store.history.single.positionSeconds, 12);
  expect(store.history.single.updatedAt, 30);
});
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
flutter test test\anime_library_store_test.dart
```

Expected: compilation fails because `AnimeLibraryStore` does not exist.

- [ ] **Step 3: Implement the store and immutable records**

Use stable keys and tolerant JSON parsing:

```dart
class AnimeFavoriteEntry {
  const AnimeFavoriteEntry({
    required this.sourceId,
    required this.animeId,
    required this.title,
    this.cover,
    required this.addedAt,
  });
  String get key => '$sourceId:$animeId';
}

class AnimeHistoryEntry {
  const AnimeHistoryEntry({
    required this.sourceId,
    required this.animeId,
    required this.title,
    this.cover,
    required this.episodeId,
    required this.episodeName,
    required this.episodeIndex,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.updatedAt,
  });
  String get key => '$sourceId:$animeId';
}
```

`AnimeLibraryStore` must provide `load`, `favorites`, `history`, `isFavorite`, `toggleFavorite`, `saveProgress`, `removeHistory`, `clearHistory`, `flushPending`, `exportData`, `importData`, and `dispose`. Store JSON under `anime.library.v1` and `anime.history.v1`; skip malformed individual records and rewrite repaired collections.

- [ ] **Step 4: Run GREEN and commit**

Run `flutter test test\anime_library_store_test.dart`, then:

```powershell
git add lib\app\anime_library_store.dart test\anime_library_store_test.dart
git commit -m "feat(anime): persist favorites and playback history"
```

### Task 2: Expose anime library state through the app

**Files:**
- Modify: `lib/app/app.dart`
- Modify: `lib/app/anime_library_store.dart`
- Create: `test/app_anime_library_scope_test.dart`

- [ ] **Step 1: Write a failing App scope test**

```dart
testWidgets('app loads and exposes anime library state', (tester) async {
  SharedPreferences.setMockInitialValues(const {});
  await tester.pumpWidget(App(downloadCoordinator: coordinator));
  expect(find.byType(AnimeLibraryScope), findsOneWidget);
});
```

- [ ] **Step 2: Verify RED**

Run `flutter test test\app_anime_library_scope_test.dart`; expect `AnimeLibraryScope` to be missing.

- [ ] **Step 3: Add the scope and lifecycle**

Add `AnimeLibraryScope extends InheritedNotifier<AnimeLibraryStore>` with `of`, `read`, and `maybeRead`. In `_AppState`, create `_animeLibrary`, load it beside manga/novel stores, wrap the application under `AnimeLibraryScope`, call `flushPending()` in explicit app-exit persistence paths, and dispose it after removing listeners.

- [ ] **Step 4: Run GREEN and commit**

Run `flutter test test\app_anime_library_scope_test.dart test\app_anime_download_scope_test.dart`, then commit:

```powershell
git add lib\app\app.dart lib\app\anime_library_store.dart test\app_anime_library_scope_test.dart
git commit -m "feat(app): expose anime library state"
```

### Task 3: Project three stores into one ordered history

**Files:**
- Create: `lib/features/library/unified_history.dart`
- Create: `test/unified_history_test.dart`

- [ ] **Step 1: Write failing projection tests**

Build records at timestamps `30`, `20`, and `10`; assert anime, novel, manga order. Add equal-timestamp records and assert the stable tie-breaker `(kind.index, key)`.

```dart
final items = UnifiedHistoryProjector.build(
  manga: [mangaAt(10)],
  novel: [novelAt(20)],
  anime: [animeAt(30)],
);
expect(items.map((item) => item.kind), [
  UnifiedHistoryKind.anime,
  UnifiedHistoryKind.novel,
  UnifiedHistoryKind.manga,
]);
```

- [ ] **Step 2: Verify RED**

Run `flutter test test\unified_history_test.dart`; expect missing projector/model failures.

- [ ] **Step 3: Implement a pure projection model**

Create `UnifiedHistoryKind`, `UnifiedHistoryItem`, and `UnifiedHistoryProjector.build`. The projector receives already-resolved novel `(entry, progress)` records, does not mutate any store, sorts by descending `updatedAt`, then by kind and stable key. Preserve type-specific payloads so the UI does not reconstruct IDs from strings.

- [ ] **Step 4: Run GREEN and commit**

```powershell
flutter test test\unified_history_test.dart
git add lib\features\library\unified_history.dart test\unified_history_test.dart
git commit -m "feat(library): merge content history chronologically"
```

### Task 4: Resume anime playback at the stored second

**Files:**
- Modify: `lib/features/anime/playback/player_adapter.dart`
- Modify: `lib/features/anime/playback/media_kit_player_adapter.dart`
- Modify: `lib/features/anime/playback/playback_session_controller.dart`
- Modify: `lib/features/anime/playback/playback_state.dart`
- Modify: `lib/features/anime/anime_player_page.dart`
- Modify: `test/playback_session_controller_test.dart`
- Modify: `test/anime_player_page_test.dart`

- [ ] **Step 1: Write failing resume and progress tests**

Add tests proving:

```dart
await controller.start(
  const [track],
  track,
  initialPosition: const Duration(seconds: 83),
);
expect(adapter.seeks, [const Duration(seconds: 83)]);
```

Also assert position callbacks report integer seconds once per changed second, duration is captured, a near-end resume resets to zero, and changing episode flushes the old episode before recording the new one.

- [ ] **Step 2: Verify RED**

Run:

```powershell
flutter test test\playback_session_controller_test.dart test\anime_player_page_test.dart
```

Expected: `initialPosition`, duration, and history callbacks are absent.

- [ ] **Step 3: Extend the player contract and controller**

Add `Stream<Duration> get duration` to `PlayerAdapter` and adapters/fakes. Extend `PlaybackState` with duration. Extend `PlaybackSessionController`:

```dart
Future<void> start(
  List<VideoTrack> available,
  VideoTrack selected, {
  Duration initialPosition = Duration.zero,
}) async {
  _position = initialPosition;
  await _open(selected,
      generation: ++_generation, resume: initialPosition > Duration.zero);
}
```

Subscribe to duration and call an injected `void Function(Duration position, Duration duration)? onProgress` only when the integer second changes. Before seek, reset to zero when duration is known and `duration - initialPosition <= const Duration(seconds: 10)`.

- [ ] **Step 4: Connect `AnimePlayerPage` to `AnimeLibraryStore`**

Add `initialPosition` and optional test callback parameters. On load/start, pass the initial position. On progress, call `saveProgress` with the current source/anime/episode metadata. On pause, episode switch, and `dispose`, call `flushPending()` after the last in-memory update. Do not write URLs, headers, cookies, or selected lines to history.

- [ ] **Step 5: Run GREEN and commit**

```powershell
flutter test test\playback_session_controller_test.dart test\anime_player_page_test.dart
git add lib\features\anime\playback lib\features\anime\anime_player_page.dart test\playback_session_controller_test.dart test\anime_player_page_test.dart
git commit -m "feat(anime): resume playback to the stored second"
```

### Task 5: Add anime favorites and a reusable history resume route

**Files:**
- Modify: `lib/features/anime/anime_detail_page.dart`
- Create: `lib/features/anime/anime_history_resume.dart`
- Create: `test/anime_favorite_test.dart`
- Create: `test/anime_history_resume_test.dart`

- [ ] **Step 1: Write failing favorite and resume tests**

Assert the detail action toggles `AnimeLibraryStore.isFavorite`. For resume, use a fake source whose episodes have IDs `ep-1`, `ep-2`; verify ID match wins over a stale index, missing ID falls back to a clamped index, and resolution errors leave the history record intact.

- [ ] **Step 2: Verify RED**

Run `flutter test test\anime_favorite_test.dart test\anime_history_resume_test.dart`; expect missing favorite UI and resume helper failures.

- [ ] **Step 3: Implement favorite UI and resume resolver**

Add a keyed favorite icon to `AnimeDetailPage` using the loaded detail title/cover when available. Implement:

```dart
Future<void> openAnimeHistory(
  BuildContext context,
  AnimeHistoryEntry entry, {
  MangaSource Function(SourceMeta meta) sourceBuilder = buildSource,
}) async
```

Resolve `SourceMeta`, fetch chapters, choose by episode ID then valid index, dispose the temporary source, and push `AnimePlayerPage(initialPosition: Duration(seconds: entry.positionSeconds))`. Surface errors through the existing app snackbar/dialog style without deleting history.

- [ ] **Step 4: Run GREEN and commit**

```powershell
flutter test test\anime_favorite_test.dart test\anime_history_resume_test.dart
git add lib\features\anime\anime_detail_page.dart lib\features\anime\anime_history_resume.dart test\anime_favorite_test.dart test\anime_history_resume_test.dart
git commit -m "feat(anime): add favorites and history resume"
```

### Task 6: Replace the split history page with one mixed list

**Files:**
- Modify: `lib/features/library/history_page.dart`
- Delete: `lib/features/library/library_kind_switch.dart`
- Create: `test/unified_history_page_test.dart`

- [ ] **Step 1: Write failing widget tests**

Host `HistoryPage` under all three scopes. Assert no `SegmentedButton` exists, mixed rows follow timestamp order, anime progress renders `12:34`, per-row delete affects only its Store, and clear-all empties all three.

- [ ] **Step 2: Verify RED**

Run `flutter test test\unified_history_page_test.dart`; expect the existing manga/novel switch and missing anime row.

- [ ] **Step 3: Implement mixed rows and deletion dispatch**

Build items through `UnifiedHistoryProjector`. Switch on `UnifiedHistoryKind` for cover, progress text, open action, and delete action. The clear confirmation runs manga `clearHistory`, novel `clearHistory`, and anime `clearHistory` in one operation. Use `openAnimeHistory` for anime rows.

- [ ] **Step 4: Run GREEN and commit**

```powershell
flutter test test\unified_history_page_test.dart
git add lib\features\library\history_page.dart lib\features\library\library_kind_switch.dart test\unified_history_page_test.dart
git commit -m "feat(library): show one mixed history list"
```

### Task 7: Build the unified library home with three favorite sections

**Files:**
- Modify: `lib/features/library/library_page.dart`
- Create: `test/unified_library_page_test.dart`

- [ ] **Step 1: Write failing home layout tests**

Seed one history item of each kind and one favorite of each kind. Assert section order:

```dart
expect(
  sectionTitles(tester),
  ['历史记录', '漫画收藏', '小说收藏', '番剧收藏'],
);
expect(find.byType(SegmentedButton), findsNothing);
```

Add a search test proving one query filters manga, novel, and anime favorites while history/recommendations are hidden during search.

- [ ] **Step 2: Verify RED**

Run `flutter test test\unified_library_page_test.dart`; expect the split page and absent anime section.

- [ ] **Step 3: Consolidate `LibraryPage`**

Remove `LibraryKind` state and `_NovelLibraryPage`; make the existing manga page the single scaffold. Remove `LibraryKindSwitch`, keep search/import/refresh/history actions, and order body children as unified history, manga favorites, novel favorites, anime favorites, then recommendation/browser content. Reuse `openNovelLibraryEntry`, `NovelCover`, `MangaCover`, and `AnimeDetailPage`; do not duplicate persistence logic in widgets.

Show compact empty states for all three favorite sections. Limit the home history strip to 12 items and link its header/action to `HistoryPage`.

- [ ] **Step 4: Run GREEN and commit**

```powershell
flutter test test\unified_library_page_test.dart test\novel_library_view_test.dart
git add lib\features\library\library_page.dart test\unified_library_page_test.dart
git commit -m "feat(library): combine content shelves on the home page"
```

### Task 8: Localize, verify compatibility, and record deferred runtime checks

**Files:**
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_zh_Hant.arb`
- Modify generated localization files through `flutter gen-l10n` (ignored by Git)
- Modify: `docs/superpowers/plans/2026-08-06-unified-library-history.md`

- [ ] **Step 1: Add localization keys**

Add these exact keys in all four ARB files, then run `flutter gen-l10n`:

```text
libraryUnifiedHistory
libraryMangaFavorites
libraryNovelFavorites
libraryAnimeFavorites
libraryHistoryEmpty
libraryMangaFavoritesEmpty
libraryNovelFavoritesEmpty
libraryAnimeFavoritesEmpty
animeFavorite
animeUnfavorite
animeHistoryProgress
animeResumeFailed
```

- [ ] **Step 2: Run the focused suite**

Run all new/changed tests, excluding the previously known hanging `anime_detail_download_test.dart` and `anime_downloads_view_test.dart` until the combined validation stage:

```powershell
flutter test test\anime_library_store_test.dart test\app_anime_library_scope_test.dart test\unified_history_test.dart test\playback_session_controller_test.dart test\anime_player_page_test.dart test\anime_favorite_test.dart test\anime_history_resume_test.dart test\unified_history_page_test.dart test\unified_library_page_test.dart test\novel_library_view_test.dart
```

- [ ] **Step 3: Run focused analysis and diff checks**

Run `dart analyze` on touched production/test Dart files, then `git diff --check` and `git status --short`. Do not run Windows/Android builds, packaging, or device playback tests.

- [ ] **Step 4: Commit localization and plan completion**

```powershell
git add lib\l10n\app_*.arb docs\superpowers\plans\2026-08-06-unified-library-history.md
git commit -m "chore(l10n): localize unified library history"
```

## Deferred combined validation

- Windows build and tray/runtime smoke test.
- Android build and real-device background behavior.
- Real anime source playback, second-accurate exit/resume, episode switching, and near-end restart.
- Cloud/server synchronization for the new anime data category.
- Investigation of the two existing hanging anime Widget tests.
