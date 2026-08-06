# Windows Download Tray Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Windows downloads continue when the user closes the main window, with an explicit direct-exit setting and tray menu.

**Architecture:** The existing native Runner owns the tray icon and intercepts `WM_CLOSE`. Dart persists a Windows-local `closeToTray` preference and sends it over a small method channel. The tray can restore the main window or explicitly exit; no third-party tray plugin is added.

**Tech Stack:** Flutter MethodChannel, SharedPreferences, Win32 `Shell_NotifyIcon`, existing Windows Runner.

---

### Task 1: Persist and bridge close behavior

**Files:**
- Create: `lib/core/platform/windows_window_bridge.dart`
- Modify: `lib/app/library_store.dart`
- Create: `test/windows_window_bridge_test.dart`

- [x] Test method-channel deduplication and local preference persistence.
- [x] Add a dedicated notifier and Windows-only bridge.

### Task 2: Add native tray behavior

**Files:**
- Modify: `windows/runner/flutter_window.h`
- Modify: `windows/runner/flutter_window.cpp`
- Modify: `windows/runner/main.cpp`
- Modify: `windows/runner/CMakeLists.txt`

- [x] Register the window channel, create/remove the tray icon, hide on close when enabled, restore on double-click/menu, and quit only through direct close or the tray Exit command.

### Task 3: Add the desktop setting

**Files:**
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `lib/l10n/app_*.arb`
- Modify generated localization output via `flutter gen-l10n`.
- Modify: `lib/app/app.dart`

- [x] Add the Windows-only close-to-tray toggle and synchronize its value after load and changes.
- [x] Run focused Dart tests and static analysis; defer Windows build/runtime tray verification to the combined validation stage.
