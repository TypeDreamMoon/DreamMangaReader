import 'dart:convert';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/features/novel/novel_document_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 在真 QuickJS 里跑小说阅读器的注入桥,验证「点在链接/按钮/输入框上不翻页」的
/// 守卫真的生效 —— 用 stub 的 document/window 喂事件,断言 dmrCommand 的调用次数。
///
/// 桥脚本的**文本**断言(CSS/监听器是否写对)留在 test/novel_reader_test.dart;
/// 这里要建 [JsEngine],普通 `flutter test` 加载不到 QuickJS 原生库。
///
/// 运行:flutter test integration_test/novel_reader_bridge_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('interactive elements block wheel and touch page commands', () {
    final engine = JsEngine();
    addTearDown(engine.dispose);
    engine.evalSync(r'''
      const listeners = {};
      const commands = [];
      globalThis.window = globalThis;
      globalThis.innerWidth = 1000;
      globalThis.innerHeight = 800;
      globalThis.CSS = {escape: (value) => value};
      globalThis.document = {
        scrollingElement: {
          scrollLeft: 0, scrollTop: 0,
          scrollWidth: 3000, scrollHeight: 3000,
          scrollTo: () => {}
        },
        documentElement: {dataset: {}},
        querySelectorAll: () => [],
        querySelector: () => null,
        getElementById: () => ({textContent: ''}),
        addEventListener: (type, listener) => { listeners[type] = listener; }
      };
      globalThis.addEventListener = () => {};
      window.flutter_inappwebview = {
        callHandler: (channel, command) => commands.push([channel, command])
      };
    ''');
    engine.evalSync(novelReaderBridgeScript);

    final result = jsonDecode(engine.evalSync(r'''
      const interactive = {closest: () => ({})};
      const plain = {closest: () => null};
      const touch = (target, x, y) => ({
        target,
        changedTouches: [{clientX: x, clientY: y}]
      });
      let prevented = 0;
      listeners.wheel({
        target: interactive,
        deltaY: 100,
        preventDefault: () => { prevented++; }
      });
      const interactiveWheelCalls = commands.length;
      listeners.wheel({
        target: plain,
        deltaY: 100,
        preventDefault: () => { prevented++; }
      });
      const plainWheelCalls = commands.length;
      commands.length = 0;
      listeners.touchstart(touch(interactive, 800, 100));
      listeners.touchend(touch(plain, 100, 100));
      const interactiveTouchCalls = commands.length;
      listeners.touchstart(touch(plain, 800, 100));
      listeners.touchend(touch(plain, 100, 100));
      const plainTouchCalls = commands.length;
      JSON.stringify({
        interactiveWheelCalls,
        plainWheelCalls,
        interactiveTouchCalls,
        plainTouchCalls,
        prevented
      });
    ''')) as Map<String, dynamic>;

    expect(result['interactiveWheelCalls'], 0);
    expect(result['plainWheelCalls'], 1);
    expect(result['interactiveTouchCalls'], 0);
    expect(result['plainTouchCalls'], 1);
  });
}
