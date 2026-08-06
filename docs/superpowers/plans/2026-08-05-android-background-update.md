# Android Background Update Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Android APK updates into a resumable foreground service with system notifications while preserving the current Windows updater.

**Architecture:** A shared Dart transfer model keeps the dialog platform-neutral. Windows adapts the existing `UpdateDownloader`; Android serializes the selected `ResolvedUpdateAsset` through a platform bridge to a native Kotlin foreground service that owns download, retry, verification, notifications, and installation intents.

**Tech Stack:** Flutter/Dart, Kotlin, Android foreground services, MethodChannel/EventChannel, HttpURLConnection, SharedPreferences, NotificationCompat, FileProvider, flutter_test.

---

## File Map

- Create `lib/core/update/update_transfer.dart`: shared transfer state, coordinator interface, and Windows adapter.
- Create `lib/core/update/android_update_bridge.dart`: Android plan serialization, state decoding, channel client, and URL sanitization.
- Create `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadPlan.kt`: strict native plan parsing and safe file rules.
- Create `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadState.kt`: persisted state JSON contract.
- Create `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadService.kt`: foreground download worker and notifications.
- Create `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadBridge.kt`: Flutter channels, permissions, broadcasts, foreground detection, and installer intents.
- Create `android/app/src/main/res/xml/update_file_paths.xml`: scoped FileProvider path for verified APKs.
- Modify `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/MainActivity.kt`: delegate engine, lifecycle, permission, and Intent hooks to the bridge.
- Modify `android/app/src/main/AndroidManifest.xml`: permissions, service, and FileProvider declarations.
- Modify `lib/core/update/update_service.dart`: coordinator-driven dialog and refreshed-link retry.
- Modify `lib/l10n/app_*.arb` and `test/l10n_test.dart`: background-update UI text.
- Create `test/update_transfer_test.dart`, `test/android_update_bridge_test.dart`, and `test/android_update_native_contract_test.dart`.
- Modify `test/update_dialog_test.dart`: background, cancel, restore, ready, and expired-link behavior.
- Create `android/app/src/test/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadPlanTest.kt`: native plan validation tests for author/CI execution.

## Task 1: Add the Shared Transfer Domain

**Files:**
- Create: `lib/core/update/update_transfer.dart`
- Create: `test/update_transfer_test.dart`
- Modify: `lib/core/update/update_service.dart`

- [ ] **Step 1: Write the failing transfer-state and Windows-adapter tests**

```dart
test('Windows coordinator emits downloading then ready', () async {
  final file = File('${temp.path}/setup.exe')..writeAsBytesSync([1, 2, 3]);
  final coordinator = WindowsUpdateTransferCoordinator(
    download: (asset, {required cancelToken, required onProgress}) async {
      onProgress(.5);
      onProgress(1);
      return file;
    },
    install: (package, {onBeforeExit}) async {},
  );
  final states = <UpdateTransferState>[];
  final subscription = coordinator.states.listen(states.add);

  await coordinator.start(candidate: candidate, asset: asset);

  expect(states.map((state) => state.stage), containsAllInOrder([
    UpdateTransferStage.downloading,
    UpdateTransferStage.verifying,
    UpdateTransferStage.ready,
  ]));
  expect((await coordinator.current()).packagePath, file.path);
  await subscription.cancel();
});

test('cancel keeps the coordinator reusable', () async {
  final coordinator = WindowsUpdateTransferCoordinator(
    download: (asset, {required cancelToken, required onProgress}) =>
        cancelToken.whenCancel.then<File>((error) => throw error),
    install: (package, {onBeforeExit}) async {},
  );
  unawaited(coordinator.start(candidate: candidate, asset: asset));
  await coordinator.cancel();
  expect((await coordinator.current()).stage, UpdateTransferStage.idle);
});
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```powershell
flutter test test/update_transfer_test.dart
```

Expected: compilation fails because `update_transfer.dart` and its types do not exist.

- [ ] **Step 3: Implement the shared interface and Windows adapter**

```dart
enum UpdateTransferStage {
  idle,
  downloading,
  retrying,
  verifying,
  assembling,
  ready,
  error,
}

@immutable
class UpdateTransferState {
  const UpdateTransferState({
    required this.stage,
    this.taskKey,
    this.versionName,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.progress = 0,
    this.message,
    this.packagePath,
    this.errorCode,
  });

  const UpdateTransferState.idle()
      : this(stage: UpdateTransferStage.idle);

  final UpdateTransferStage stage;
  final String? taskKey;
  final String? versionName;
  final int downloadedBytes;
  final int totalBytes;
  final double progress;
  final String? message;
  final String? packagePath;
  final String? errorCode;

  bool get busy => switch (stage) {
        UpdateTransferStage.downloading ||
        UpdateTransferStage.retrying ||
        UpdateTransferStage.verifying ||
        UpdateTransferStage.assembling => true,
        _ => false,
      };
}

abstract interface class UpdateTransferCoordinator {
  bool get supportsBackground;
  Stream<UpdateTransferState> get states;
  Future<UpdateTransferState> current();
  Future<void> start({
    required UpdateCandidate candidate,
    required ResolvedUpdateAsset asset,
  });
  Future<void> cancel();
  Future<void> install({Future<void> Function()? onBeforeExit});
  Future<void> dispose();
}
```

Implement `WindowsUpdateTransferCoordinator` with one broadcast controller, one `CancelToken`, and one verified package path. It calls the existing injected download callback, converts progress `>= 1` to `verifying`, emits `ready`, and delegates installation without changing `UpdateDownloader`.

- [ ] **Step 4: Run transfer and existing downloader tests**

Run:

```powershell
flutter test test/update_transfer_test.dart test/update_downloader_test.dart
```

Expected: all tests pass; existing Range and chunk behavior remains green.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/update/update_transfer.dart lib/core/update/update_service.dart test/update_transfer_test.dart
git commit -m "refactor(updates): model platform transfer state"
```

## Task 2: Define the Dart-to-Android Contract

**Files:**
- Create: `lib/core/update/android_update_bridge.dart`
- Create: `test/android_update_bridge_test.dart`

- [ ] **Step 1: Write failing serialization, state, and redaction tests**

```dart
test('serializes a chunked Android plan without source tokens outside URLs', () {
  final plan = AndroidUpdatePlan.fromAsset(
    versionName: '1.7.0',
    asset: chunkedAsset,
  ).toJson();
  expect(plan['schemaVersion'], 1);
  expect(plan['taskKey'], '${chunkedAsset.sha256}:1.7.0');
  expect((plan['parts'] as List).length, 2);
  expect(plan['sizeBytes'], chunkedAsset.sizeBytes);
});

test('decodes a persisted ready state', () {
  final state = AndroidUpdateState.fromJson({
    'status': 'ready',
    'taskKey': 'abc:1.7.0',
    'versionName': '1.7.0',
    'downloadedBytes': 30,
    'totalBytes': 30,
    'percent': 100.0,
    'apkPath': '/data/user/0/app/files/updates/app.apk',
  });
  expect(state.stage, UpdateTransferStage.ready);
  expect(state.packagePath, endsWith('app.apk'));
});

test('redacts signed URL query parameters from platform errors', () {
  expect(
    sanitizeUpdateError(
      'Connection closed, uri=https://foruda.gitee.com/a.apk?token=secret&ts=1',
    ),
    isNot(anyOf(contains('secret'), contains('token='), contains('ts='))),
  );
});
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```powershell
flutter test test/android_update_bridge_test.dart
```

Expected: compilation fails because `AndroidUpdatePlan`, `AndroidUpdateState`, and `sanitizeUpdateError` do not exist.

- [ ] **Step 3: Implement the plan and bridge client**

```dart
class AndroidUpdatePlan {
  AndroidUpdatePlan._(this._json);
  final Map<String, Object?> _json;

  factory AndroidUpdatePlan.fromAsset({
    required String versionName,
    required ResolvedUpdateAsset asset,
  }) {
    if (asset.platform != UpdatePlatform.android) {
      throw const FormatException('Android update plan requires Android asset.');
    }
    final json = <String, Object?>{
      'schemaVersion': 1,
      'taskKey': '${asset.sha256.toLowerCase()}:$versionName',
      'versionName': versionName,
      'fileName': asset.fileName,
      'sizeBytes': asset.sizeBytes,
      'sha256': asset.sha256.toLowerCase(),
      if (!asset.isChunked) 'url': asset.url,
      if (asset.isChunked)
        'parts': [
          for (final part in asset.parts)
            {
              'fileName': part.fileName,
              'url': part.url,
              'sizeBytes': part.sizeBytes,
              'sha256': part.sha256.toLowerCase(),
            },
        ],
    };
    return AndroidUpdatePlan._(Map.unmodifiable(json));
  }

  Map<String, Object?> toJson() => Map.of(_json);
}
```

Implement `AndroidUpdateState.fromJson` with a closed mapping from the native status strings to `UpdateTransferStage`; reject unknown status, invalid byte counts, progress outside `0..100`, and `ready` without `apkPath`.

Implement `AndroidUpdateBridge` with:

```dart
static const _methods = MethodChannel('dream_manga_reader/update');
static const _events = EventChannel('dream_manga_reader/update_events');

Future<void> start(AndroidUpdatePlan plan) =>
    _methods.invokeMethod('startUpdateDownload', plan.toJson());
Future<void> cancel() => _methods.invokeMethod('cancelUpdateDownload');
Future<AndroidUpdateState> current() async => AndroidUpdateState.fromJson(
    Map<String, Object?>.from(
      await _methods.invokeMapMethod<String, Object?>('getUpdateDownloadState') ??
          const {'status': 'idle'},
    ));
Future<void> installReady() => _methods.invokeMethod('installReadyUpdate');
Stream<AndroidUpdateState> get states => _events
    .receiveBroadcastStream()
    .map((value) => AndroidUpdateState.fromJson(
        Map<String, Object?>.from(value as Map)));
```

`sanitizeUpdateError` must parse URL-shaped substrings and replace each query with an empty query. Map native code `expired_url` to “下载地址已过期，请重试”。

- [ ] **Step 4: Run bridge tests**

Run:

```powershell
flutter test test/android_update_bridge_test.dart
```

Expected: all plan, state, mock-channel, and redaction tests pass.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/update/android_update_bridge.dart test/android_update_bridge_test.dart
git commit -m "feat(android): define background update bridge"
```

## Task 3: Register the Native Bridge and Foreground Service Contract

**Files:**
- Create: `test/android_update_native_contract_test.dart`
- Create: `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadBridge.kt`
- Create: `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadPlan.kt`
- Create: `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadState.kt`
- Create: `android/app/src/main/res/xml/update_file_paths.xml`
- Modify: `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/MainActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Extend the XML/source contract test and verify RED**

```dart
test('Android declares a private data-sync update service', () {
  final manifest = XmlDocument.parse(
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
  );
  final permissions = manifest.findAllElements('uses-permission').map(
    (element) => element.getAttribute('name', namespace: androidNamespace),
  );
  expect(permissions, containsAll({
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
    'android.permission.WAKE_LOCK',
  }));
  final service = manifest.findAllElements('service').singleWhere(
    (element) => element
        .getAttribute('name', namespace: androidNamespace)!
        .endsWith('UpdateDownloadService'),
  );
  expect(service.getAttribute('exported', namespace: androidNamespace), 'false');
  expect(service.getAttribute('foregroundServiceType', namespace: androidNamespace), 'dataSync');
  expect(service.getAttribute('stopWithTask', namespace: androidNamespace), 'false');
});

test('native bridge exposes the complete Flutter contract', () {
  final source = File(
    'android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update/'
    'UpdateDownloadBridge.kt',
  ).readAsStringSync();
  for (final method in [
    'startUpdateDownload',
    'cancelUpdateDownload',
    'getUpdateDownloadState',
    'installReadyUpdate',
  ]) {
    expect(source, contains('"$method"'));
  }
});
```

Run:

```powershell
flutter test test/android_update_native_contract_test.dart
```

Expected: failures for missing permissions, service, bridge, and provider.

- [ ] **Step 2: Add the strict plan and state types**

Implement `UpdateDownloadPlan.parse(JSONObject)` with these exact invariants:

```kotlin
require(source.getInt("schemaVersion") == 1)
require(versionName.isNotBlank())
require(taskKey == "${sha256.lowercase()}:$versionName")
require(sizeBytes > 0L)
require(SHA256.matches(sha256))
require(isSafeLeafName(fileName))
require(parts.isEmpty() xor url.isNullOrBlank())
require(parts.sumOf { it.sizeBytes } == sizeBytes)
```

`isSafeLeafName` rejects `/`, `\\`, `..`, blank values, and names different from `File(value).name`. Every URL must use `https`.

`UpdateDownloadState` must serialize only status, task identity, byte counts, percent, message, error code, and verified APK path. It must not serialize any download URL.

- [ ] **Step 3: Add Manifest declarations and bridge delegation**

Add the four permissions, private provider `${applicationId}.update_provider`, and service:

```xml
<service
    android:name=".update.UpdateDownloadService"
    android:exported="false"
    android:foregroundServiceType="dataSync"
    android:stopWithTask="false" />
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="${applicationId}.update_provider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/update_file_paths" />
</provider>
```

`update_file_paths.xml` exposes only `<files-path name="updates" path="updates/" />`.

Modify `MainActivity` to instantiate `UpdateDownloadBridge`, call `configure(flutterEngine)`, and forward `onResume`, `onPause`, `onNewIntent`, `onRequestPermissionsResult`, and `onDestroy`.

- [ ] **Step 4: Implement bridge start/cancel/state/install behavior**

The bridge must request `POST_NOTIFICATIONS` on API 33+, call `ContextCompat.startForegroundService`, register a non-exported state receiver, expose an EventChannel sink, and open a verified ready APK with:

```kotlin
val uri = FileProvider.getUriForFile(
    activity,
    "${activity.packageName}.update_provider",
    apk,
)
val intent = Intent(Intent.ACTION_VIEW).apply {
    setDataAndType(uri, "application/vnd.android.package-archive")
    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
}
activity.startActivity(intent)
```

When a `ready` broadcast arrives while `onResume` is active, call the same installer method once per task key. When the notification opens `MainActivity` with action `INSTALL_READY_UPDATE`, defer installation until the bridge and Flutter activity are resumed.

- [ ] **Step 5: Run static contract tests**

Run:

```powershell
flutter test test/android_update_native_contract_test.dart test/android_network_security_test.dart
```

Expected: all Android XML and source-contract tests pass.

- [ ] **Step 6: Commit**

```powershell
git add android/app/src/main test/android_update_native_contract_test.dart
git commit -m "feat(android): register background update service"
```

## Task 4: Implement Resumable Native Downloads

**Files:**
- Create: `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadService.kt`
- Create: `android/app/src/test/kotlin/com/dreammoon/dream_manga_reader/update/UpdateDownloadPlanTest.kt`
- Modify: `test/android_update_native_contract_test.dart`

- [ ] **Step 1: Add failing native plan tests and executable source contracts**

```kotlin
@Test fun rejectsTraversalAndHttpUrls() {
    assertFailsWith<IllegalArgumentException> {
        UpdateDownloadPlan.parse(plan(fileName = "../app.apk"))
    }
    assertFailsWith<IllegalArgumentException> {
        UpdateDownloadPlan.parse(plan(url = "http://example/app.apk"))
    }
}

@Test fun acceptsOrderedPartsWhoseSizesMatchTheFinalAsset() {
    val parsed = UpdateDownloadPlan.parse(chunkedPlan())
    assertEquals(2, parsed.parts.size)
    assertEquals(parsed.sizeBytes, parsed.parts.sumOf { it.sizeBytes })
}
```

Extend the Dart source contract to require `Range`, `Content-Range`, `MAX_ATTEMPTS = 3`, `PARTIAL_WAKE_LOCK`, `START_REDELIVER_INTENT`, `expired_url`, final SHA-256 verification, PackageManager package-name validation, and the notification channel ID.

Run locally:

```powershell
flutter test test/android_update_native_contract_test.dart
```

Expected: fails because the service implementation does not exist.

The Kotlin JVM tests are committed for author/CI execution. Do not restore the deleted Android Gradle cache locally.

- [ ] **Step 2: Implement service lifecycle and persisted state**

Use `ACTION_START`, `ACTION_CANCEL`, `ACTION_STATE`, `EXTRA_PLAN`, and `EXTRA_STATE`. On start:

```kotlin
override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == ACTION_CANCEL) {
        cancelRequested.set(true)
        return START_NOT_STICKY
    }
    val planJson = intent?.getStringExtra(EXTRA_PLAN)
        ?: preferences.getString(PREF_PLAN, null)
        ?: return stopWithError("没有可恢复的更新任务")
    preferences.edit().putString(PREF_PLAN, planJson).apply()
    startForegroundCompat(buildProgressNotification(0, "正在准备更新"))
    if (running.compareAndSet(false, true)) executor.execute { runPlan(planJson) }
    return START_REDELIVER_INTENT
}
```

Acquire a Partial WakeLock for at most 30 minutes, release it in `finally`, stop foreground without deleting completion/error notification, and publish every state to SharedPreferences plus a package-scoped broadcast.

- [ ] **Step 3: Implement one-file resume and retry**

For each remote file:

```kotlin
for (attempt in 1..MAX_ATTEMPTS) {
    try {
        downloadOnce(remote, partialFile)
        break
    } catch (error: IOException) {
        if (attempt == MAX_ATTEMPTS || !isRetryable(error)) throw error
        publishRetrying(remote, partialFile.length(), attempt + 1)
        Thread.sleep(500L * attempt)
    }
}
```

`downloadOnce` sends Range from current length. Accept only 200 or 206; validate the `Content-Range` start for 206; truncate on 200; classify 401/403 as `expired_url`; classify 5xx, timeout, and connection close as retryable. Persist progress no more often than every 350 ms.

- [ ] **Step 4: Implement verification, chunk assembly, and APK validation**

Verify every downloaded file before rename. For chunked plans, download and verify each part, stream parts into `<final>.assembling`, check cancellation while copying, verify final size/SHA-256, then rename to the final APK.

Use `PackageManager.getPackageArchiveInfo` with `GET_SIGNING_CERTIFICATES` on API 28+ and reject a candidate whose package name differs from `applicationContext.packageName`. Publish `ready` only after all checks pass.

- [ ] **Step 5: Implement notifications and cleanup**

Create low-importance channel `dream_manga_reader_updates`. Progress notification is ongoing and contains a cancel PendingIntent. Completion notification opens `MainActivity` with `INSTALL_READY_UPDATE`; error notification contains only `sanitizeForUser(message)` and never a URL query.

Active interruption retains `.download` files. Explicit cancel deletes the complete update root and clears preferences. Starting a different task key removes files from the previous task.

- [ ] **Step 6: Run locally available tests**

Run:

```powershell
flutter test test/android_update_native_contract_test.dart
```

Expected: all static service contracts pass.

Author/CI command after dependencies are available:

```powershell
android\gradlew.bat :app:testDebugUnitTest --console=plain --no-daemon
```

Expected: `UpdateDownloadPlanTest` passes.

- [ ] **Step 7: Commit**

```powershell
git add android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update android/app/src/test test/android_update_native_contract_test.dart
git commit -m "feat(android): download updates in foreground service"
```

## Task 5: Connect the Dialog, Retry, and Localized UI

**Files:**
- Modify: `lib/core/update/update_service.dart`
- Modify: `test/update_dialog_test.dart`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_zh_Hant.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`
- Modify: `test/l10n_test.dart`

- [ ] **Step 1: Rewrite dialog tests against a fake coordinator and verify RED**

```dart
testWidgets('background button closes without cancelling Android transfer',
    (tester) async {
  final coordinator = FakeUpdateTransferCoordinator(background: true);
  await openDialog(tester, coordinator: coordinator);
  await tester.tap(find.byKey(const Key('update-primary')));
  coordinator.emit(downloadingState(progress: .25));
  await tester.pump();
  await tester.tap(find.byKey(const Key('update-background')));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsNothing);
  expect(coordinator.cancelCount, 0);
});

testWidgets('restores an existing transfer instead of starting a duplicate',
    (tester) async {
  final coordinator = FakeUpdateTransferCoordinator(
    background: true,
    initial: downloadingState(progress: .6, taskKey: expectedTaskKey),
  );
  await openDialog(tester, coordinator: coordinator);
  expect(find.textContaining('60%'), findsOneWidget);
  expect(coordinator.startCount, 0);
});

testWidgets('expired Gitee URL refreshes the candidate before retry',
    (tester) async {
  final coordinator = FakeUpdateTransferCoordinator(
    background: true,
    initial: errorState(code: 'expired_url'),
  );
  var refreshes = 0;
  await openDialog(
    tester,
    coordinator: coordinator,
    refresh: (_) async { refreshes++; return refreshedCandidate; },
  );
  await tester.tap(find.byKey(const Key('update-retry')));
  await tester.pumpAndSettle();
  expect(refreshes, 1);
  expect(coordinator.startedAsset?.url, refreshedAsset.url);
});
```

Run:

```powershell
flutter test test/update_dialog_test.dart
```

Expected: failures because dependencies still expose foreground callbacks and there is no background button/state restore.

- [ ] **Step 2: Replace callback ownership with a coordinator**

Change `UpdateDialogDependencies` to:

```dart
typedef UpdateRefreshCallback = Future<UpdateCandidate?> Function(
  UpdateSource preferred,
);

@immutable
class UpdateDialogDependencies {
  const UpdateDialogDependencies({
    required this.coordinator,
    required this.refresh,
    required this.openManual,
  });
  final UpdateTransferCoordinator coordinator;
  final UpdateRefreshCallback refresh;
  final UpdateManualCallback openManual;
}
```

Production returns `AndroidUpdateTransferCoordinator(AndroidUpdateBridge())` on Android and `WindowsUpdateTransferCoordinator` elsewhere. `refresh` calls `UpdateService.check(preferredSource: source)` and returns only `updateAvailable` candidates.

- [ ] **Step 3: Drive dialog state from the coordinator**

On init, select the current compatible asset, subscribe to `coordinator.states`, then read `coordinator.current()`. Restore only when task key matches `<sha256>:<candidate.version>`. Starting calls `coordinator.start`; cancel awaits `coordinator.cancel`; ready calls install only when the coordinator has not already delegated foreground installation to Android.

Add `update-background` next to cancel only when `supportsBackground` and state is busy. It pops the dialog without disposing the app-owned native service. The dialog cancels its Stream subscription in `dispose` but never cancels the transfer implicitly.

- [ ] **Step 4: Refresh expired links and preserve partial files**

When `errorCode == 'expired_url'`, retry must call `refresh(_active.source)`, rerun ABI selection, require the same version and final SHA-256, and then start with the fresh URL. A different version or SHA-256 becomes a newly prepared task rather than reusing old partial files.

- [ ] **Step 5: Add localized strings and regenerate localizations**

Add equivalent keys to all four ARB files:

```json
"update_background": "后台下载",
"update_backgroundHint": "下载将在系统通知中继续",
"update_retrying": "连接中断，正在重试 {attempt} / 3",
"update_readyNotification": "更新已下载，点击安装",
"update_notificationPermission": "需要通知权限才能在后台安全下载更新",
"update_expiredUrl": "下载地址已过期，请重试"
```

Use natural translations in English, Japanese, and Traditional Chinese; add keys to `test/l10n_test.dart`. Run `flutter gen-l10n` before widget tests.

- [ ] **Step 6: Run dialog, localization, and updater regression tests**

Run:

```powershell
flutter gen-l10n
flutter test test/update_dialog_test.dart test/update_transfer_test.dart test/android_update_bridge_test.dart test/l10n_test.dart test/update_downloader_test.dart
```

Expected: all tests pass; Windows behavior remains covered by the Windows coordinator tests.

- [ ] **Step 7: Commit**

```powershell
git add lib/core/update/update_service.dart lib/l10n test/update_dialog_test.dart test/l10n_test.dart
git commit -m "feat(updates): continue Android downloads in background"
```

## Task 6: Final Verification and Author Handoff

**Files:**
- Modify if needed: `docs/superpowers/specs/2026-08-05-android-background-update-design.md`
- Verify: all files changed by Tasks 1-5

- [ ] **Step 1: Run formatting and focused tests**

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter test test/update_transfer_test.dart test/android_update_bridge_test.dart test/android_update_native_contract_test.dart test/update_dialog_test.dart test/update_downloader_test.dart test/l10n_test.dart
```

Expected: formatting unchanged and all focused tests pass.

- [ ] **Step 2: Run full Flutter verification**

```powershell
flutter test
flutter analyze
git diff --check
```

Expected: full test suite passes, analyzer reports no issues, and diff check is clean.

- [ ] **Step 3: Review security and behavior requirements**

Verify from the final diff:

- no logged or displayed URL query strings;
- service and provider are non-exported;
- FileProvider exposes only `files/updates/`;
- notification permission gates service start on Android 13+;
- explicit cancel removes partial files, network failure keeps them;
- 401/403 produces `expired_url` and refreshed-link retry;
- Windows still uses `UpdateDownloader`;
- update detection does not auto-start a download.

- [ ] **Step 4: Record the unexecuted Android checks**

Do not download Gradle/Android caches or build packages locally. The PR handoff must ask the author to run:

```powershell
android\gradlew.bat :app:testDebugUnitTest --console=plain --no-daemon
flutter build apk --release --split-per-abi
```

It must also list real-device checks: notification denial, background/lock-screen download, network interruption and resume, system service reclamation, completion notification install, foreground auto-install, and same-signature replacement.

- [ ] **Step 5: Commit any verification-only corrections**

```powershell
git status --short
git add <only-the-files-corrected-during-verification>
git commit -m "test(updates): verify Android background lifecycle"
```

Skip this commit when verification requires no code or test corrections.
