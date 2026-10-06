import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _runner(String name) =>
    File('windows/runner/$name').readAsStringSync();

void main() {
  test('a second launch hands off to the running instance and exits', () {
    // 关闭默认收进托盘,窗口藏起来时用户很容易再点一次快捷方式。没有命名互斥体就会
    // 多出第二个托盘图标、第二份下载队列和第二份云同步,两份还抢同一批持久化文件。
    final main = _runner('main.cpp');
    expect(main, contains('CreateMutexW'));
    expect(main, contains('ERROR_ALREADY_EXISTS'));
    // 已有实例时必须自己退出,而不是继续建窗口。
    final guard = main.substring(main.indexOf('ERROR_ALREADY_EXISTS'));
    final body = guard.substring(0, guard.indexOf('AttachConsole'));
    expect(body, contains('return EXIT_SUCCESS;'));
    // 新进程握着前台权,得让给已有实例,否则对方撞前台锁只显示不激活。
    expect(body, contains('AllowSetForegroundWindow(ASFW_ANY)'));
    // 广播能送到隐藏的顶层窗口;消息 id 全系统唯一,别的程序不会误认。
    expect(body, contains('HWND_BROADCAST'));
    expect(body, contains('ShowExistingInstanceMessage()'));
  });

  test('the running instance answers the handoff by leaving the tray', () {
    final source = _runner('flutter_window.cpp');
    expect(
      source,
      contains('RegisterWindowMessageW(L"DreamMangaReaderShowExistingInstance")'),
    );
    final handler = source.substring(
      source.indexOf('FlutterWindow::MessageHandler'),
    );
    final upToClose = handler.substring(0, handler.indexOf('WM_CLOSE'));
    expect(upToClose, contains('message == ShowExistingInstanceMessage()'));
    expect(upToClose, contains('ShowFromTray();'));
    // 声明要对 main.cpp 可见。
    expect(_runner('flutter_window.h'), contains('ShowExistingInstanceMessage'));
  });
}
