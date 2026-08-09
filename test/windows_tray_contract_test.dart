import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _runner(String name) =>
    File('windows/runner/$name').readAsStringSync();

void main() {
  test('tray icon opts into the modern shell callback protocol', () {
    // 不调 NIM_SETVERSION 时外壳沿用 Win95 协议:左键单击不回调任何事件,只有双击
    // 才有反应 —— 用户点一下没动静,体感就是「托盘点击要等半天才打开」。
    final source = _runner('flutter_window.cpp');
    expect(source, contains('NOTIFYICON_VERSION_4'));
    expect(source, contains('NIM_SETVERSION'));
    expect(source, contains('NIN_SELECT'));
    expect(source, contains('case WM_LBUTTONUP:'));
  });

  test('restoring from the tray reclaims foreground, focus and the cursor',
      () {
    final source = _runner('flutter_window.cpp');
    // 前台锁会让 SetForegroundWindow 静默失败,窗口显示出来却没被激活。
    expect(source, contains('AttachThreadInput'));
    // 焦点要还给 Flutter 视图,不是外层框架窗口。
    expect(source, contains('FlutterViewWindow()'));
    // 指针显示计数在隐藏期间可能停在负数,恢复时必须拉回可见并重发 WM_SETCURSOR。
    expect(source, contains('ShowCursor(TRUE)'));
    expect(source, contains('WM_SETCURSOR'));
    expect(_runner('flutter_window.h'), contains('RestoreCursor'));
  });
}
