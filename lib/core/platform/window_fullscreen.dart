import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

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
  WindowFullscreen._();

  static final WindowFullscreen instance = WindowFullscreen._();

  /// 仅 Windows 有实现。别的平台一律 false,按钮据此隐藏。
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows && Platform.isWindows;

  bool _on = false;
  bool get isFullscreen => _on;

  int _savedStyle = 0;
  int _savedLeft = 0;
  int _savedTop = 0;
  int _savedWidth = 0;
  int _savedHeight = 0;

  /// 返回切换后的状态。不支持的平台原样返回 false。
  bool toggle() => _on ? exit() : enter();

  bool enter() {
    if (!supported || _on) return _on;
    final hwnd = GetActiveWindow();
    if (hwnd == 0) return false;

    final rect = calloc<RECT>();
    final info = calloc<MONITORINFO>();
    try {
      if (GetWindowRect(hwnd, rect) == 0) return false;
      _savedStyle = GetWindowLongPtr(hwnd, GWL_STYLE);
      _savedLeft = rect.ref.left;
      _savedTop = rect.ref.top;
      _savedWidth = rect.ref.right - rect.ref.left;
      _savedHeight = rect.ref.bottom - rect.ref.top;

      // 用窗口当前所在的那块屏,多显示器下才不会跳到主屏去。
      final monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      info.ref.cbSize = sizeOf<MONITORINFO>();
      if (GetMonitorInfo(monitor, info) == 0) return false;
      final m = info.ref.rcMonitor;

      SetWindowLongPtr(hwnd, GWL_STYLE, _savedStyle & ~WS_OVERLAPPEDWINDOW);
      SetWindowPos(
        hwnd,
        HWND_TOP,
        m.left,
        m.top,
        m.right - m.left,
        m.bottom - m.top,
        SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
      );
      _on = true;
      return true;
    } finally {
      calloc.free(rect);
      calloc.free(info);
    }
  }

  bool exit() {
    if (!supported || !_on) return false;
    final hwnd = GetActiveWindow();
    if (hwnd == 0) return _on;
    SetWindowLongPtr(hwnd, GWL_STYLE, _savedStyle);
    SetWindowPos(
      hwnd,
      HWND_TOP,
      _savedLeft,
      _savedTop,
      _savedWidth,
      _savedHeight,
      SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
    );
    _on = false;
    return false;
  }
}
