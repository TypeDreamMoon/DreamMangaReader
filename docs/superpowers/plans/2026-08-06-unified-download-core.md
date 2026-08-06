# Unified Download Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the durable, cross-platform task model, policy engine, scheduler, and application scope that later manga, novel, anime, and app-update executors share.

**Architecture:** A Dart `DownloadCoordinator` owns all mutable task state and persists immutable task records through an atomic JSON repository. Content-specific executors register by `DownloadContentKind`; the coordinator applies policy gates, bounded concurrency, cancellation generations, and restart recovery without knowing resource formats.

**Tech Stack:** Dart, Flutter `ChangeNotifier`/`InheritedNotifier`, `dart:io` atomic file replacement, `flutter_test`.

**Scope:** This is plan 1 of 3. It does not migrate the existing manga/novel stores, add the new download-center UI, implement platform background services, or download HLS media. Those are follow-up plans built on the types established here.

---

## File Map

- Create `lib/core/downloads/download_task.dart`: immutable task record, enums, progress, serialization, and validated transitions.
- Create `lib/core/downloads/download_failure.dart`: stable failure codes and sanitized user-facing failure data.
- Create `lib/core/downloads/download_task_repository.dart`: repository contract and atomic JSON file implementation.
- Create `lib/core/downloads/download_policy.dart`: network, roaming, storage, and low-battery policy snapshot/evaluation.
- Create `lib/core/downloads/download_executor.dart`: executor contract, execution context, progress/checkpoint callbacks, and cancellation token.
- Create `lib/core/downloads/download_coordinator.dart`: queue ownership, policy gating, bounded scheduler, persistence, and restart recovery.
- Create `lib/app/download_coordinator_scope.dart`: application-level inherited notifier.
- Modify `lib/app/app.dart`: create, load, expose, and dispose the coordinator.
- Create `test/support/download_fixtures.dart`: shared deterministic task, environment, repository, and executor fakes used by focused tests.
- Create corresponding tests under `test/`.

### Task 1: Serializable Task Model

**Files:**
- Create: `lib/core/downloads/download_task.dart`
- Create: `test/support/download_fixtures.dart`
- Test: `test/download_task_test.dart`

- [ ] **Step 1: Write failing round-trip and validation tests**

Create records with `manga`, `novel`, `anime`, and `appUpdate` kinds. Assert JSON round trips, progress clamps to `0..1`, completed tasks require `completedAt`, and credentials/URLs are absent from serialized keys.

```dart
test('task round trips without transport secrets', () {
  final task = DownloadTask(
    id: 'manga:source:book:chapter',
    kind: DownloadContentKind.manga,
    title: '测试漫画',
    itemTitle: '第 1 话',
    state: DownloadTaskState.queued,
    createdAt: 100,
    updatedAt: 100,
    completedBytes: 5,
    totalBytes: 10,
    priority: 7,
    payload: const {'sourceId': 'source', 'mangaId': 'book'},
  );

  final encoded = task.toJson();
  expect(encoded.keys, isNot(contains('headers')));
  expect(encoded.keys, isNot(contains('url')));
  expect(DownloadTask.fromJson(encoded), task);
  expect(task.progress, 0.5);
});
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `flutter test test/download_task_test.dart`

Expected: FAIL because `DownloadTask` and its enums do not exist.

- [ ] **Step 3: Implement the immutable model and explicit enum codecs**

Define these exact public types:

```dart
enum DownloadContentKind { anime, manga, novel, appUpdate }

enum DownloadTaskState {
  resolving,
  queued,
  running,
  verifying,
  completed,
  paused,
  failed,
  cancelled,
}

enum DownloadPauseReason {
  user,
  wifi,
  storage,
  auth,
  sourceRefresh,
  system,
  externalStorage,
}

final class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.kind,
    required this.title,
    required this.itemTitle,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    required this.completedBytes,
    required this.totalBytes,
    required this.priority,
    required this.payload,
    this.pauseReason,
    this.completedAt,
  });

  double get progress => totalBytes <= 0
      ? 0
      : (completedBytes / totalBytes).clamp(0.0, 1.0);
}
```

Implement `copyWith`, value equality, `toJson`, and `fromJson`. Serialize enums by `.name` and reject unknown values with `FormatException`. Copy payload into an unmodifiable map and reject reserved keys `url`, `urls`, `headers`, `cookie`, `token`, `key`, and `authorization`, case-insensitively and recursively.

Add this fixture to `test/support/download_fixtures.dart` and use overrides rather than duplicating records in later tests:

```dart
DownloadTask taskFixture({
  String id = 'manga:source:book:chapter',
  DownloadContentKind kind = DownloadContentKind.manga,
  DownloadTaskState state = DownloadTaskState.queued,
  int priority = 0,
}) {
  return DownloadTask(
    id: id,
    kind: kind,
    title: '作品',
    itemTitle: '子项',
    state: state,
    createdAt: 100,
    updatedAt: 100,
    completedBytes: 0,
    totalBytes: 100,
    priority: priority,
    payload: const {'sourceId': 'source', 'contentId': 'book'},
    completedAt: state == DownloadTaskState.completed ? 200 : null,
  );
}
```

- [ ] **Step 4: Run the focused test**

Run: `flutter test test/download_task_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/downloads/download_task.dart test/support/download_fixtures.dart test/download_task_test.dart
git commit -m "feat(downloads): define durable task model"
```

### Task 2: Stable Failure Model

**Files:**
- Create: `lib/core/downloads/download_failure.dart`
- Modify: `lib/core/downloads/download_task.dart`
- Test: `test/download_failure_test.dart`

- [ ] **Step 1: Write failing failure-classification tests**

Cover network timeout, `401`, `403`, `404`, disk-full, path rejection, corrupt resource, unsupported DRM, and unknown errors. Assert signed query values are removed from details.

```dart
test('sanitizes signed URLs from persisted failure detail', () {
  final failure = DownloadFailure.fromMessage(
    DownloadFailureCode.sourceRefreshRequired,
    'GET https://cdn.test/a.ts?token=secret&expires=123 returned 403',
  );
  expect(failure.detail, isNot(contains('secret')));
  expect(failure.detail, contains('https://cdn.test/a.ts'));
});
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `flutter test test/download_failure_test.dart`

Expected: FAIL because `DownloadFailure` is undefined.

- [ ] **Step 3: Implement stable codes and sanitization**

```dart
enum DownloadFailureCode {
  network,
  authenticationRequired,
  sourceRefreshRequired,
  resourceMissing,
  insufficientStorage,
  storageUnavailable,
  unsafePath,
  corruptResource,
  unsupportedDrm,
  cancelled,
  unknown,
}

final class DownloadFailure {
  const DownloadFailure({
    required this.code,
    required this.message,
    required this.detail,
    required this.retryCount,
    this.httpStatus,
  });
}
```

Add `toJson`, `fromJson`, value equality, and a sanitizer that removes URL query/fragment content and `Authorization`, `Cookie`, and bearer-token values before persistence.
Then add `DownloadFailure? failure` to `DownloadTask`, its `copyWith`, equality, and JSON codec. Import `download_failure.dart` from `download_task.dart`; this is the first task that introduces the failure field.

- [ ] **Step 4: Run model tests**

Run: `flutter test test/download_failure_test.dart test/download_task_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/downloads/download_failure.dart lib/core/downloads/download_task.dart test/download_failure_test.dart test/download_task_test.dart
git commit -m "feat(downloads): classify durable failures"
```

### Task 3: Atomic JSON Repository

**Files:**
- Create: `lib/core/downloads/download_task_repository.dart`
- Test: `test/download_task_repository_test.dart`

- [ ] **Step 1: Write failing persistence and recovery tests**

Use a temporary directory. Cover empty load, save/load, deterministic task order, malformed index quarantine, temporary-file recovery, schema rejection, and no secret strings in stored bytes.

```dart
test('save replaces the index atomically', () async {
  final repository = FileDownloadTaskRepository(
    rootProvider: () async => root.path,
  );
  final task = taskFixture();
  await repository.save([task]);

  final index = File('${root.path}/index.json');
  expect(await index.exists(), isTrue);
  expect(await File('${index.path}.tmp').exists(), isFalse);
  expect(await repository.load(), [task]);
});
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `flutter test test/download_task_repository_test.dart`

Expected: FAIL because the repository is undefined.

- [ ] **Step 3: Implement the repository contract and file adapter**

```dart
abstract interface class DownloadTaskRepository {
  Future<List<DownloadTask>> load();
  Future<void> save(List<DownloadTask> tasks);
}

final class FileDownloadTaskRepository implements DownloadTaskRepository {
  FileDownloadTaskRepository({required this.rootProvider});
  static const schemaVersion = 1;
  final Future<String> Function() rootProvider;
}
```

Write `{ "schemaVersion": 1, "tasks": tasks.map((task) => task.toJson()).toList() }` as UTF-8 to `index.json.tmp`, flush it, then replace `index.json`. On Windows, rename the valid old index to `index.json.previous` before replacing and remove the previous copy only after success. On load, prefer valid `index.json`, then recover from `.tmp` or `.previous`. Rename irrecoverable input to `index.json.corrupt-<timestamp>` and return an empty list.

- [ ] **Step 4: Run repository tests**

Run: `flutter test test/download_task_repository_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/downloads/download_task_repository.dart test/download_task_repository_test.dart
git commit -m "feat(downloads): persist tasks atomically"
```

### Task 4: Download Policy Engine

**Files:**
- Create: `lib/core/downloads/download_policy.dart`
- Test: `test/download_policy_test.dart`

- [ ] **Step 1: Write the failing policy matrix**

Cover Wi-Fi, metered mobile permission, roaming prohibition, unavailable storage, reserve-space threshold, and optional low-battery pause. Ensure user pause has precedence over policy evaluation in the coordinator rather than in this pure evaluator.

```dart
test('wifi-only pauses a metered mobile task', () {
  const settings = DownloadPolicySettings(wifiOnly: true);
  const environment = DownloadEnvironment(
    connected: true,
    wifi: false,
    metered: true,
    roaming: false,
    batteryLow: false,
    storageAvailable: true,
    freeBytes: 8 * gibibyte,
  );
  expect(
    evaluateDownloadPolicy(settings, environment),
    const DownloadPolicyDecision.pause(DownloadPauseReason.wifi),
  );
});
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `flutter test test/download_policy_test.dart`

Expected: FAIL because policy types are undefined.

- [ ] **Step 3: Implement immutable settings, environment, and decision types**

Defaults must be Wi-Fi only, roaming disabled, two concurrent works, 2 GiB reserved, low-battery pause disabled. Validate concurrency in `1..3` and reserve bytes as non-negative.

```dart
const int gibibyte = 1024 * 1024 * 1024;

final class DownloadPolicySettings {
  const DownloadPolicySettings({
    this.wifiOnly = true,
    this.allowRoaming = false,
    this.maxConcurrentWorks = 2,
    this.reserveBytes = 2 * gibibyte,
    this.pauseOnLowBattery = false,
  });
}

final class DownloadPolicyDecision {
  const DownloadPolicyDecision.allow()
      : allowed = true,
        pauseReason = null;

  const DownloadPolicyDecision.pause(this.pauseReason) : allowed = false;

  final bool allowed;
  final DownloadPauseReason? pauseReason;
}
```

Return explicit pause reasons; never throw for ordinary environmental restrictions.
Implement value equality for `DownloadPolicyDecision`, then add `unrestrictedEnvironment` to `test/support/download_fixtures.dart` with connected Wi-Fi, no roaming, normal battery, available storage, and 8 GiB free.

- [ ] **Step 4: Run policy tests**

Run: `flutter test test/download_policy_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/downloads/download_policy.dart test/support/download_fixtures.dart test/download_policy_test.dart
git commit -m "feat(downloads): evaluate runtime policies"
```

### Task 5: Executor Contract and Cancellation

**Files:**
- Create: `lib/core/downloads/download_executor.dart`
- Test: `test/download_executor_test.dart`

- [ ] **Step 1: Write failing progress, checkpoint, and cancellation tests**

Verify monotonic byte progress, total-byte correction, cancellation throwing `DownloadCancelledException`, and checkpoint callbacks receiving a secret-free task record.

```dart
test('cancellation prevents later progress', () async {
  final cancellation = DownloadCancellation();
  cancellation.cancel();
  expect(
    () => cancellation.throwIfCancelled(),
    throwsA(isA<DownloadCancelledException>()),
  );
});
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `flutter test test/download_executor_test.dart`

Expected: FAIL because executor types do not exist.

- [ ] **Step 3: Implement the executor boundary**

```dart
abstract interface class DownloadExecutor {
  DownloadContentKind get kind;
  Future<void> execute(DownloadExecutionContext context, DownloadTask task);
}

final class DownloadExecutionContext {
  DownloadExecutionContext({
    required this.cancellation,
    required this.reportProgress,
    required this.checkpoint,
  });

  final DownloadCancellation cancellation;
  final Future<void> Function(int completedBytes, int totalBytes)
      reportProgress;
  final Future<void> Function() checkpoint;
}
```

Executors receive only the safe payload. Transport secrets are resolved through later platform/content adapters, never added to `DownloadTask`.

- [ ] **Step 4: Run executor tests**

Run: `flutter test test/download_executor_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/downloads/download_executor.dart test/download_executor_test.dart
git commit -m "feat(downloads): define executor boundary"
```

### Task 6: Coordinator State Operations

**Files:**
- Create: `lib/core/downloads/download_coordinator.dart`
- Modify: `test/support/download_fixtures.dart`
- Test: `test/download_coordinator_test.dart`

- [ ] **Step 1: Write failing load, enqueue, pause, resume, reorder, and delete tests**

Use an in-memory repository and controllable clock. Assert duplicate IDs are rejected, every mutation persists before notification, completed tasks cannot resume, deleting an active task cancels its generation, and `pauseAll` preserves completed tasks.

```dart
test('enqueue persists before exposing the task', () async {
  final repository = RecordingDownloadTaskRepository();
  final coordinator = DownloadCoordinator(
    repository: repository,
    environment: () async => unrestrictedEnvironment,
    settings: () => const DownloadPolicySettings(),
  );
  await coordinator.load();
  await coordinator.enqueue(queuedTask);
  expect(repository.saved.single, contains(queuedTask));
  expect(coordinator.tasks, contains(queuedTask));
});
```

Define `RecordingDownloadTaskRepository` in `test/support/download_fixtures.dart`. Its `load()` returns a configurable `loaded` list and `save()` appends an immutable copy to `saved`. This makes mutation ordering observable without filesystem timing.

- [ ] **Step 2: Run the focused test and verify failure**

Run: `flutter test test/download_coordinator_test.dart`

Expected: FAIL because the coordinator is undefined.

- [ ] **Step 3: Implement serialized mutation operations**

Expose these exact operations:

```dart
Future<void> load();
Future<void> enqueue(DownloadTask task);
Future<void> pause(String id);
Future<void> resume(String id);
Future<void> pauseAll();
Future<void> resumeAll();
Future<void> retry(String id);
Future<void> reorder(String id, int priority);
Future<void> remove(String id);
```

Serialize mutations through one future tail so concurrent UI actions cannot overwrite the repository. Return unmodifiable task snapshots sorted by priority descending, then creation time ascending.

- [ ] **Step 4: Run coordinator state tests**

Run: `flutter test test/download_coordinator_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/downloads/download_coordinator.dart test/support/download_fixtures.dart test/download_coordinator_test.dart
git commit -m "feat(downloads): coordinate durable task state"
```

### Task 7: Bounded Scheduling and Restart Recovery

**Files:**
- Modify: `lib/core/downloads/download_coordinator.dart`
- Modify: `test/support/download_fixtures.dart`
- Modify: `test/download_coordinator_test.dart`

- [ ] **Step 1: Add failing scheduler tests**

Register fake executors. Verify the default concurrency is two, higher priority starts first, one executor failure does not stop other tasks, policy-paused tasks restart when `reevaluate()` is called, and persisted `running`, `resolving`, or `verifying` tasks recover to `queued` after process restart.

```dart
test('restart returns transient states to queued', () async {
  final runningTask = taskFixture(state: DownloadTaskState.running);
  final verifyingTask = taskFixture(
    id: 'novel:source:book:chapter',
    kind: DownloadContentKind.novel,
    state: DownloadTaskState.verifying,
  );
  final completedTask = taskFixture(
    id: 'anime:source:show:episode',
    kind: DownloadContentKind.anime,
    state: DownloadTaskState.completed,
  );
  repository.loaded = [runningTask, verifyingTask, completedTask];
  await coordinator.load();
  expect(coordinator.task(runningTask.id)!.state, DownloadTaskState.queued);
  expect(coordinator.task(verifyingTask.id)!.state, DownloadTaskState.queued);
  expect(coordinator.task(completedTask.id)!.state, DownloadTaskState.completed);
});
```

- [ ] **Step 2: Run the focused scheduler tests and verify failure**

Run: `flutter test test/download_coordinator_test.dart`

Expected: FAIL because scheduling and recovery are not implemented.

- [ ] **Step 3: Implement executor registration and the bounded pump**

Add:

```dart
void registerExecutor(DownloadExecutor executor);
Future<void> reevaluate();
Future<void> get idle;
DownloadTask? task(String id);
```

Allow one executor per kind. At each pump, evaluate the latest environment, select eligible queued tasks by stable order, and start no more than `maxConcurrentWorks`. Use a cancellation generation per task so late callbacks from removed/retried work cannot mutate a newer task. Map `DownloadCancelledException` to paused/cancelled intent and all other errors through `DownloadFailure`.

- [ ] **Step 4: Run coordinator and policy tests**

Run: `flutter test test/download_coordinator_test.dart test/download_policy_test.dart test/download_executor_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/downloads/download_coordinator.dart test/support/download_fixtures.dart test/download_coordinator_test.dart
git commit -m "feat(downloads): schedule and recover tasks"
```

### Task 8: Application Scope and Lifecycle

**Files:**
- Create: `lib/app/download_coordinator_scope.dart`
- Modify: `lib/app/app.dart`
- Test: `test/download_coordinator_scope_test.dart`
- Test: `test/widget_test.dart`

- [ ] **Step 1: Write failing scope and boot tests**

Assert `DownloadCoordinatorScope.of(context)` rebuilds listeners, `read(context)` does not subscribe, and `App` boots with an empty repository under a test root.

```dart
testWidgets('scope exposes the shared coordinator', (tester) async {
  late DownloadCoordinator observed;
  await tester.pumpWidget(
    DownloadCoordinatorScope(
      coordinator: coordinator,
      child: Builder(builder: (context) {
        observed = DownloadCoordinatorScope.read(context);
        return const SizedBox();
      }),
    ),
  );
  expect(observed, same(coordinator));
});
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `flutter test test/download_coordinator_scope_test.dart test/widget_test.dart`

Expected: FAIL because the scope is undefined.

- [ ] **Step 3: Implement the scope and wire the root coordinator**

```dart
class DownloadCoordinatorScope extends InheritedNotifier<DownloadCoordinator> {
  const DownloadCoordinatorScope({
    super.key,
    required DownloadCoordinator coordinator,
    required super.child,
  }) : super(notifier: coordinator);

  static DownloadCoordinator of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<DownloadCoordinatorScope>();
    assert(scope != null, 'DownloadCoordinatorScope not found');
    return scope!.notifier!;
  }

  static DownloadCoordinator read(BuildContext context) {
    final scope = context
        .getInheritedWidgetOfExactType<DownloadCoordinatorScope>();
    assert(scope != null, 'DownloadCoordinatorScope not found');
    return scope!.notifier!;
  }
}
```

Allow `App` to receive an optional `DownloadCoordinator` for widget tests. In `_AppState`, use the injected instance or create a file repository whose `rootProvider` resolves `getApplicationSupportDirectory()` plus `download-manager`. Construct one coordinator synchronously, call `load()` during startup, place the scope outside the existing manga/novel scopes, and dispose only the internally owned instance after the legacy stores. Do not register content executors in this plan.

- [ ] **Step 4: Generate localization and run scope/boot tests**

Run:

```powershell
flutter gen-l10n
flutter test test/download_coordinator_scope_test.dart test/widget_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/app/app.dart lib/app/download_coordinator_scope.dart test/download_coordinator_scope_test.dart test/widget_test.dart
git commit -m "feat(downloads): expose coordinator to the app"
```

### Task 9: Core Verification and Handoff

**Files:**
- Modify only if verification exposes a core defect.

- [ ] **Step 1: Format the new core files**

Run:

```powershell
dart format lib/core/downloads lib/app/download_coordinator_scope.dart test/download_task_test.dart test/download_failure_test.dart test/download_task_repository_test.dart test/download_policy_test.dart test/download_executor_test.dart test/download_coordinator_test.dart test/download_coordinator_scope_test.dart
```

Expected: formatter exits successfully.

- [ ] **Step 2: Run static analysis**

Run: `flutter analyze`

Expected: no issues.

- [ ] **Step 3: Run the complete test suite**

Run:

```powershell
flutter gen-l10n
flutter test
```

Expected: all tests pass; the baseline before implementation is 290 tests.

- [ ] **Step 4: Verify repository hygiene**

Run:

```powershell
git diff --check upstream/main...HEAD
git status --short
```

Expected: no whitespace errors and no uncommitted generated localization files.

- [ ] **Step 5: Record the delivered boundary**

In the final handoff, state that this phase adds the shared core only. Do not claim Android background content downloads, Windows tray behavior, the redesigned download center, legacy store migration, or anime offline playback until their follow-up plans are implemented and platform-tested.
