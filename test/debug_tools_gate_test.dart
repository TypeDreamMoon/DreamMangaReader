import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/app/app_info.dart';

String _src(String path) => File(path).readAsStringSync();

void main() {
  test('the debug tools gate is a compile-time constant tied to the build mode',
      () {
    // 必须是 const:release 下整条入口连同调试页一起被摇掉,而不是运行时判一下。
    expect(debugToolsAvailable, kDebugMode || kProfileMode);
    expect(debugToolsAvailable, isNot(kReleaseMode));
    expect(
      _src('lib/app/app_info.dart'),
      contains('const bool debugToolsAvailable = kDebugMode || kProfileMode;'),
    );
  });

  test('the about page seal only opens the debug page off release', () {
    // 关于页印章连点 5 次是隐藏入口。调试页能联网跑任意源脚本、把整页 HTML 写进
    // 应用目录,正式包里不该有这条路。
    final about = _src('lib/features/settings/about_page.dart');
    final handler = about.substring(about.indexOf('void _onSealTap()'));
    final body = handler.substring(0, handler.indexOf('@override'));
    expect(body, contains('if (!debugToolsAvailable) return;'));
    // 闸门必须在计数之前,否则连点计数照样在 release 里跑。
    expect(
      body.indexOf('debugToolsAvailable'),
      lessThan(body.indexOf('_sealTaps++')),
    );
  });

  test('the cloudflare spike page refuses to run off a debug build', () {
    // 这页会开 WebView 去过 Cloudflare 挑战并读 Cookie,只该活在调试构建里。
    final spike = _src('lib/features/spike/cloudflare_spike_page.dart');
    expect(spike, contains('if (!debugToolsAvailable) return;'));
    expect(
      spike,
      contains('if (!debugToolsAvailable) return const SizedBox.shrink();'),
    );
  });

  test('every source and JS engine the debug page builds gets disposed', () {
    // buildSource / JsEngine 每次都新建一个 QuickJS 运行时。这页上的按钮就是拿来
    // 反复点的,而且自检本来就在找抛错的情况 —— 释放必须落在 finally 里。
    final debug = _src('lib/features/debug/debug_page.dart');
    // 方法体 = 从签名到它自己那行缩进 2 格的收尾大括号。
    String bodyOf(String fn) {
      final start = debug.indexOf(RegExp('(?:void|Future<void>) $fn\\('));
      expect(start, isNonNegative, reason: '找不到 $fn');
      final rest = debug.substring(start);
      final end = rest.indexOf(RegExp(r'^  \}', multiLine: true));
      expect(end, isPositive, reason: '$fn 没有收尾');
      return rest.substring(0, end);
    }

    for (final fn in ['_runJs', '_runScript', '_runLive', '_runPages']) {
      final body = bodyOf(fn);
      expect(body, contains('} finally {'), reason: '$fn 的释放不在 finally 里');
      expect(body, contains('.dispose();'), reason: '$fn 建了引擎/源却没释放');
    }
    // 常驻的演示源也要跟着页面一起释放。
    final dispose = debug.substring(debug.indexOf('  void dispose() {'));
    expect(dispose.substring(0, dispose.indexOf('super.dispose();')),
        contains('_hello.dispose();'));
  });
}
