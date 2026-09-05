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
    // 前台锁会让 SetForegroundWindow 静默失败,窗口显示出来却没被激活。失败时用
    // 「最小化再还原」这条系统允许的前台迁移兜底。
    expect(source, contains('SetForegroundWindow(window) == FALSE'));
    expect(source, contains('SW_MINIMIZE'));
    expect(source, contains('SW_RESTORE'));
    // 焦点要还给 Flutter 视图,不是外层框架窗口。
    expect(source, contains('FlutterViewWindow()'));
    // 指针显示计数在隐藏期间可能停在负数,恢复时必须拉回可见并重发 WM_SETCURSOR。
    expect(source, contains('ShowCursor(TRUE)'));
    expect(source, contains('WM_SETCURSOR'));
    expect(_runner('flutter_window.h'), contains('RestoreCursor'));
  });

  test('restoring from the tray never tears down the IME context (#25)', () {
    final source = _runner('flutter_window.cpp');
    // AttachThreadInput 抢完前台后 detach,会把随激活刚建立的 IME 输入上下文一起
    // 拆掉 —— 从托盘恢复后搜狗/微软拼音打不出字。这条手法必须彻底消失。
    expect(source, isNot(contains('AttachThreadInput')));
    // SetFocus 对已持焦点的窗口是空操作,不会重发 WM_IME_SETCONTEXT(TRUE);
    // 先清空再设回去才是一次真实的焦点迁移。
    expect(source, contains('SetFocus(nullptr)'));
    expect(source, contains('SetFocus(target)'));
    // 输入上下文可能在隐藏期间被解绑,显式关联回默认上下文。
    expect(
      source,
      contains('ImmAssociateContextEx(target, nullptr, IACE_DEFAULT)'),
    );
    expect(source, contains('#include <imm.h>'));
    // ImmAssociateContextEx 来自 imm32,不链接会 LNK2019。
    expect(_runner('CMakeLists.txt'), contains('imm32.lib'));
  });

  test('WM_ACTIVATE still reaches DefWindowProc', () {
    // 吞掉 WM_ACTIVATE 会跳过激活的默认处理(含 IME 上下文激活),窗口拿得到焦点
    // 却没有可用的输入上下文。
    final source = _runner('win32_window.cpp');
    final activate = source.substring(source.indexOf('case WM_ACTIVATE:'));
    final body = activate.substring(0, activate.indexOf('case WM_DWM'));
    expect(body, contains('SetFocus(child_content_)'));
    expect(body, isNot(contains('return 0;')));
    expect(body, contains('break;'));
    expect(source, contains('return DefWindowProc('));
  });
}
