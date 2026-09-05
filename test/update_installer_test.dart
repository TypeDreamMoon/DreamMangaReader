import 'dart:convert';

import 'package:dream_manga_reader/core/update/update_installer.dart';
import 'package:flutter_test/flutter_test.dart';

// Windows 静默更新脚本:含中文用户名的路径必须原样保留,且脚本自己把 cmd 切到
// UTF-8 代码页——否则 cmd 按 OEM 936 解码 UTF-8 字节,路径变乱码,安装器不跑,
// 而调用方那边已经 exit(0)。
void main() {
  const setup = r'C:\Users\梦叶\AppData\Local\Temp\dmr\DreamMangaReader-setup.exe';
  const exe = r'C:\Users\梦叶\AppData\Local\Programs\梦漫\dream_manga_reader.exe';

  String script() => UpdateInstaller.buildWindowsUpdateScript(
        setupPath: setup,
        exePath: exe,
      );

  test('chcp 65001 sits on its own line right after @echo off', () {
    final lines = script().split('\r\n');
    expect(lines[0], '@echo off');
    expect(lines[1], 'chcp 65001 >NUL');
    // chcp 之后那一行会被 cmd 读坏,必须是可牺牲的注释而不是真命令。
    expect(lines[2].trimLeft().toLowerCase(), startsWith('rem '));
  });

  test('non-ASCII installer and app paths survive verbatim', () {
    final text = script();
    expect(text, contains('"$setup" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'));
    expect(text, contains('start "" "$exe"'));
    expect(text, contains('梦叶'));
    expect(text, contains('梦漫'));
  });

  test('script bytes are UTF-8 without a BOM', () {
    final bytes = utf8.encode(script());
    // BOM 会被 cmd 当成命令的一部分,首行直接报错。
    expect(bytes.take(3), isNot([0xEF, 0xBB, 0xBF]));
    expect(utf8.decode(bytes), script());
  });

  test('still waits for the app to exit, restarts it and self-deletes', () {
    final lines = script().split('\r\n');
    expect(lines, contains('timeout /t 2 /nobreak >NUL'));
    expect(lines, contains(r'del "%~f0"'));
    expect(
      lines.indexOf('timeout /t 2 /nobreak >NUL'),
      lessThan(lines.indexWhere((l) => l.startsWith('"$setup"'))),
    );
  });
}
