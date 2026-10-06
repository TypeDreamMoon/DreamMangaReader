import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// 窗口矩形(逻辑上就是 RECT,只是不带指针,方便测试里造假)。
typedef WindowBounds = ({int left, int top, int width, int height});

/// [WindowFullscreen] 用到的全部窗口系统调用。抽出来只有一个目的:让「进入时记住
/// 哪个窗口、退出时还操作它」这条逻辑能被单测覆盖 —— 真机上这些是 FFI,测试环境
/// 里根本没有窗口。
@visibleForTesting
abstract class WindowFullscreenOps {
  /// 当前线程的活动窗口;没有(失焦 / 别的程序在前台)时返回 0。
  int activeWindow();
  WindowBounds? windowBounds(int hwnd);

  /// 窗口所在那块屏的矩形。
  WindowBounds? monitorBounds(int hwnd);
  int windowStyle(int hwnd);
  void setWindowStyle(int hwnd, int style);
  void setBounds(int hwnd, WindowBounds bounds);
}

/// 把**操作系统窗口**切成无边框全屏(Windows)。
///
/// 为什么不用 media_kit 自带的 `toggleFullscreen`:它是往根 Navigator 上再推一个
/// 路由,路由里只有一个光秃秃的 `Video`,`controls` 用的是我们传的
/// `NoVideoControls` —— 于是全屏之后**一个控件都没有**,而键盘监听和手势层都还留在
/// 被盖住的那一层上。进去就出不来。
///
/// 这里改成只动窗口:播放页自己那套 chrome(顶栏 / 底栏 / 手势 / 快捷键)原封不动
/// 继续工作,退出全屏永远有路。
///
/// 用的是标准做法(去掉 WS_OVERLAPPEDWINDOW 边框 + 拉到显示器工作区),退出时把
/// 原来的样式和位置放回去。移动端不需要:播放页本来就是沉浸式横屏。
class WindowFullscreen {
  WindowFullscreen._(this._ops) : _assumeSupported = false;

  /// 单测入口:注入假的窗口系统,并跳过平台判断。
  @visibleForTesting
  WindowFullscreen.forTesting(this._ops) : _assumeSupported = true;

  static final WindowFullscreen instance =
      WindowFullscreen._(const _Win32Ops());

  final WindowFullscreenOps _ops;
  final bool _assumeSupported;

  /// 仅 Windows 有实现。别的平台一律 false,按钮据此隐藏。
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows && Platform.isWindows;

  bool get _usable => _assumeSupported || supported;

  bool _on = false;
  bool get isFullscreen => _on;

  /// 进入全屏时的那个窗口。**退出必须认它**,不能重新问一次活动窗口:
  /// `GetActiveWindow` 返回的是本线程当前的活动窗口,用户切到别的程序、或者弹了个
  /// 系统对话框,它就是 0 —— 拿 0 去退出等于什么都不做,窗口永远卡在无边框全屏里。
  int _hwnd = 0;
  int _savedStyle = 0;
  int _savedLeft = 0;
  int _savedTop = 0;
  int _savedWidth = 0;
  int _savedHeight = 0;

  /// 返回切换后的状态。不支持的平台原样返回 false。
  bool toggle() => _on ? exit() : enter();

  bool enter() {
    if (!_usable || _on) return _on;
    final hwnd = _ops.activeWindow();
    if (hwnd == 0) return false;
    final bounds = _ops.windowBounds(hwnd);
    if (bounds == null) return false;
    // 用窗口当前所在的那块屏,多显示器下才不会跳到主屏去。
    final monitor = _ops.monitorBounds(hwnd);
    if (monitor == null) return false;

    // 句柄和样式一起记:样式只对这一个窗口有意义。
    _hwnd = hwnd;
    _savedStyle = _ops.windowStyle(hwnd);
    _savedLeft = bounds.left;
    _savedTop = bounds.top;
    _savedWidth = bounds.width;
    _savedHeight = bounds.height;

    _ops.setWindowStyle(hwnd, _savedStyle & ~WS_OVERLAPPEDWINDOW);
    _ops.setBounds(hwnd, monitor);
    _on = true;
    return true;
  }

  bool exit() {
    if (!_usable || !_on) return false;
    final hwnd = _hwnd;
    if (hwnd == 0) {
      // 理论上进不来(_on 为真必然记过句柄),真进来了也别把状态卡死。
      _on = false;
      return false;
    }
    _ops.setWindowStyle(hwnd, _savedStyle);
    _ops.setBounds(hwnd, (
      left: _savedLeft,
      top: _savedTop,
      width: _savedWidth,
      height: _savedHeight,
    ));
    _on = false;
    _hwnd = 0;
    _savedStyle = 0;
    return false;
  }
}

/// 真身:直接转发到 win32。
class _Win32Ops implements WindowFullscreenOps {
  const _Win32Ops();

  @override
  int activeWindow() => GetActiveWindow();

  @override
  WindowBounds? windowBounds(int hwnd) {
    final rect = calloc<RECT>();
    try {
      if (GetWindowRect(hwnd, rect) == 0) return null;
      return (
        left: rect.ref.left,
        top: rect.ref.top,
        width: rect.ref.right - rect.ref.left,
        height: rect.ref.bottom - rect.ref.top,
      );
    } finally {
      calloc.free(rect);
    }
  }

  @override
  WindowBounds? monitorBounds(int hwnd) {
    final info = calloc<MONITORINFO>();
    try {
      final monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      info.ref.cbSize = sizeOf<MONITORINFO>();
      if (GetMonitorInfo(monitor, info) == 0) return null;
      final m = info.ref.rcMonitor;
      return (
        left: m.left,
        top: m.top,
        width: m.right - m.left,
        height: m.bottom - m.top,
      );
    } finally {
      calloc.free(info);
    }
  }

  @override
  int windowStyle(int hwnd) => GetWindowLongPtr(hwnd, GWL_STYLE);

  @override
  void setWindowStyle(int hwnd, int style) =>
      SetWindowLongPtr(hwnd, GWL_STYLE, style);

  @override
  void setBounds(int hwnd, WindowBounds bounds) {
    SetWindowPos(
      hwnd,
      HWND_TOP,
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
      SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
    );
  }
}
