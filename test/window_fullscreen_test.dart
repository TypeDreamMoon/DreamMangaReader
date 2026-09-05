import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/platform/window_fullscreen.dart';

const _overlappedWindow = 0x00CF0000; // WS_OVERLAPPEDWINDOW

/// 假窗口系统:记下每一次样式/位置改动,并允许把「当前活动窗口」置为 0
/// (真机上失焦、或别的程序在前台时就是这样)。
class _FakeOps implements WindowFullscreenOps {
  _FakeOps({this.active = 100});

  int active;
  int style = _overlappedWindow | 0x10000000; // + WS_VISIBLE
  WindowBounds bounds = (left: 40, top: 60, width: 1280, height: 720);
  WindowBounds monitor = (left: 0, top: 0, width: 2560, height: 1440);
  final List<(int, int)> styleWrites = [];
  final List<(int, WindowBounds)> boundsWrites = [];

  @override
  int activeWindow() => active;

  @override
  WindowBounds? windowBounds(int hwnd) => bounds;

  @override
  WindowBounds? monitorBounds(int hwnd) => monitor;

  @override
  int windowStyle(int hwnd) => style;

  @override
  void setWindowStyle(int hwnd, int value) {
    style = value;
    styleWrites.add((hwnd, value));
  }

  @override
  void setBounds(int hwnd, WindowBounds value) {
    bounds = value;
    boundsWrites.add((hwnd, value));
  }
}

void main() {
  test('entering strips the frame and fills the monitor', () {
    final ops = _FakeOps();
    final fs = WindowFullscreen.forTesting(ops);

    expect(fs.enter(), isTrue);
    expect(fs.isFullscreen, isTrue);
    expect(ops.styleWrites.single.$1, 100);
    expect(ops.styleWrites.single.$2 & _overlappedWindow, 0);
    expect(ops.boundsWrites.single.$2, ops.monitor);
  });

  // 回归:exit() 过去重新问一次 GetActiveWindow。用户全屏后切到别的程序再按 Esc,
  // 它返回 0,exit() 直接掉头就走 —— 窗口永远卡在无边框全屏里,退无可退。
  test('exiting uses the window captured on entry, not the active one', () {
    final ops = _FakeOps();
    final fs = WindowFullscreen.forTesting(ops);
    fs.enter();
    final savedStyle = _overlappedWindow | 0x10000000;

    ops.active = 0; // 失焦
    expect(fs.exit(), isFalse);

    expect(fs.isFullscreen, isFalse);
    // 样式和位置都还给了进入时那个句柄。
    expect(ops.styleWrites.last, (100, savedStyle));
    expect(ops.boundsWrites.last,
        (100, (left: 40, top: 60, width: 1280, height: 720)));
  });

  test('the active window moving elsewhere does not misdirect the restore',
      () {
    final ops = _FakeOps();
    final fs = WindowFullscreen.forTesting(ops);
    fs.enter();

    ops.active = 999; // 前台换成了另一个窗口
    fs.exit();

    expect(ops.styleWrites.last.$1, 100);
    expect(ops.boundsWrites.last.$1, 100);
  });

  test('a saved style never leaks into the next window', () {
    final ops = _FakeOps();
    final fs = WindowFullscreen.forTesting(ops);
    fs.enter();
    fs.exit();

    // 第二轮换了个窗口、换了套样式:恢复的必须是这一轮记下的。
    ops.active = 777;
    ops.style = 0x00080000; // WS_SYSMENU 之类,和上一轮完全不同
    ops.bounds = (left: 5, top: 6, width: 800, height: 600);
    fs.enter();
    ops.active = 0;
    fs.exit();

    expect(ops.styleWrites.last, (777, 0x00080000));
    expect(
      ops.boundsWrites.last,
      (777, (left: 5, top: 6, width: 800, height: 600)),
    );
  });

  test('toggle round-trips', () {
    final ops = _FakeOps();
    final fs = WindowFullscreen.forTesting(ops);
    expect(fs.toggle(), isTrue);
    expect(fs.toggle(), isFalse);
    expect(fs.isFullscreen, isFalse);
  });

  test('no active window means no half-entered state', () {
    final ops = _FakeOps(active: 0);
    final fs = WindowFullscreen.forTesting(ops);
    expect(fs.enter(), isFalse);
    expect(fs.isFullscreen, isFalse);
    expect(ops.styleWrites, isEmpty);
  });
}
