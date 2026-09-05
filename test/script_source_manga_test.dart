import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/source.dart';

void main() {
  /// 回归 E3:`ScriptSource` 的构造函数就 eval 脚本,坏脚本会从构造里抛出来。
  /// 引擎是构造前建好、由外部传进来的,抛出时还没有人持有它 —— 旧代码于是每探测
  /// 一次坏源就漏一个 QuickJS 运行时。
  group('a script that fails to load', () {
    test('disposes the engine it was handed', () {
      final engine = _FakeEngine(failOn: 'boom');
      expect(
        () => ScriptSource(
          engine: engine,
          http: _NoHttp(),
          scriptCode: 'boom',
        ),
        throwsA(isA<JsEngineException>()),
      );
      expect(engine.disposeCount, 1, reason: '构造失败必须回收引擎');
    });

    test('disposes the engine when __source.meta is missing', () {
      final engine = _FakeEngine(metaJson: 'null');
      expect(
        () => ScriptSource(
          engine: engine,
          http: _NoHttp(),
          scriptCode: 'var __source = {};',
        ),
        throwsA(anything),
      );
      expect(engine.disposeCount, 1);
    });

    test('a successful load keeps the engine alive until dispose', () {
      final engine = _FakeEngine();
      final source = ScriptSource(
        engine: engine,
        http: _NoHttp(),
        scriptCode: 'var __source = {};',
      );
      expect(engine.disposeCount, 0);
      expect(source.id, 'fake');
      source.dispose();
      expect(engine.disposeCount, 1);
    });
  });
}

/// 不碰原生 QuickJS 的假引擎:只回答 [ScriptSource] 构造期问的那几个 eval。
class _FakeEngine implements JsEngine {
  _FakeEngine({this.failOn, this.metaJson = '{"id":"fake","name":"Fake"}'});

  /// eval 到含这段文本的代码就抛(模拟脚本语法错 / 运行时抛出)。
  final String? failOn;
  final String metaJson;
  int disposeCount = 0;

  @override
  String evalSync(String code) {
    final boom = failOn;
    if (boom != null && code.contains(boom)) {
      throw JsEngineException('SyntaxError: unexpected token');
    }
    if (code.contains('__source.meta')) return metaJson;
    if (code.contains('__source.filters')) return 'null';
    if (code.contains('__source.sections')) return 'null';
    return '';
  }

  @override
  void onMessage(String channel, dynamic Function(dynamic message) handler) {}

  @override
  void dispose() => disposeCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoHttp implements HttpService {
  @override
  Future<HostResponse> fetch(HostRequest request) =>
      throw UnimplementedError('fetch');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
