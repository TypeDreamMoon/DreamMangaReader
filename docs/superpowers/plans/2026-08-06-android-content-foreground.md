# Android Content Foreground Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep unified content downloads visible and process-prioritized while the Android app is backgrounded or locked.

**Architecture:** Dart remains the owner of source execution, HLS packaging, persistence, retry, and policy. A small Android `dataSync` foreground service mirrors aggregate coordinator progress through a method channel, owns the notification and a bounded partial WakeLock, and stops automatically when Dart reports no active work or stops reporting. It does not receive URLs, headers, cookies, tokens, or source payloads.

**Tech Stack:** Flutter MethodChannel, Android Kotlin Service, NotificationCompat, existing `DownloadCoordinator`.

---

### Task 1: Aggregate safe notification state

**Files:**
- Create: `lib/core/downloads/android_download_foreground.dart`
- Create: `test/android_download_foreground_test.dart`

- [ ] Test active-state filtering, aggregate progress, and safe title-only payloads.
- [ ] Implement snapshot generation and a method-channel bridge with start/update/stop deduplication.
- [ ] Run the focused Dart test.

### Task 2: Add the native foreground service

**Files:**
- Create: `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/downloads/ContentDownloadForegroundService.kt`
- Create: `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/downloads/ContentDownloadBridge.kt`
- Create: `android/app/src/test/kotlin/com/dreammoon/dream_manga_reader/downloads/ContentDownloadStateTest.kt`
- Modify: `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/MainActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] Test native state parsing clamps progress and rejects invalid counts.
- [ ] Implement notification permission handling, service start/update/stop, app-open intent, WakeLock, and two-minute stale timeout.
- [ ] Register the non-exported `dataSync` service and bridge.

### Task 3: Connect the coordinator lifecycle

**Files:**
- Modify: `lib/app/app.dart`
- Test: `test/android_download_foreground_test.dart`

- [ ] Attach the bridge after coordinator load, sync on coordinator changes, and remove the Dart listener on dispose without force-stopping valid native work.
- [ ] Run focused Dart tests and static analysis only; defer Gradle/Android builds and device background tests to the combined validation stage.
