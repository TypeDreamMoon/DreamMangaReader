import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:dream_manga_reader/core/script/js_engine.dart';

/// 在真机/真平台(-d windows / -d android)上验证 flutter_js(QuickJS)可用。
/// 普通 `flutter test`(Dart VM)加载不到原生库,所以必须走 integration_test。
///
/// 运行:flutter test integration_test/js_engine_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('flutter_js (QuickJS) evaluates JS on this platform',
      (tester) async {
    final js = JsEngine();
    addTearDown(js.dispose);

    // 基本求值
    expect(js.evalSync('1 + 2'), '3');

    // 源脚本会用到的能力:IIFE + 对象 + 数组 + JSON + Unicode 字符串
    final r = js.evalSync(
      '(function(){'
      '  const d = { t: "墨染之约", c: [1, 2, 3] };'
      '  return JSON.stringify({ n: d.c.length, len: d.t.length });'
      '})()',
    );
    expect(r, '{"n":3,"len":4}');
  });
}
