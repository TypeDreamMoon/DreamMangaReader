import 'dart:io' show sleep;

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_health.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';

const _budget = Duration(milliseconds: 20);

/// 一个「跑得比预算久」的求值器,模拟退化正则 / 死循环。
String _slow(String code) {
  sleep(const Duration(milliseconds: 60));
  return 'never-used';
}

/// 一个「网络挂了」的源:用来确认普通失败没被误判成 scriptStuck。
class _BoomSource implements MangaSource {
  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('network down');
}

/// 构建时就卡住的源:ScriptSource 的构造函数本身也会 evalSync,行为要一致。
MangaSource _stuckBuilder(SourceMeta meta) {
  final engine =
      JsEngine.withEvaluator(_slow, label: meta.id, budget: _budget);
  engine.evalSync('/* parse */');
  throw StateError('unreachable');
}

void main() {
  // 看门狗把超时记进 AppLog,AppLog 要 SchedulerBinding。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => JsWatchdog.instance.reset());

  group('JsEngine 执行预算', () {
    test('超预算的求值判失败,并带上是谁、跑了多久', () {
      final engine =
          JsEngine.withEvaluator(_slow, label: 'demo', budget: _budget);
      Object? caught;
      try {
        engine.evalSync('while(true){}');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<JsExecutionOverrun>());
      final over = caught! as JsExecutionOverrun;
      expect(over.label, 'demo');
      expect(over.elapsed, greaterThan(_budget));
      expect(over.codePreview, contains('while(true)'));
    });

    test('超预算后引擎熔断:后续求值立刻失败,不再冻第二次', () {
      var calls = 0;
      final engine = JsEngine.withEvaluator(
        (code) {
          calls++;
          sleep(const Duration(milliseconds: 60));
          return 'x';
        },
        label: 'demo',
        budget: _budget,
      );
      expect(() => engine.evalSync('a'), throwsA(isA<JsExecutionOverrun>()));
      expect(engine.isBlown, isTrue);

      final sw = Stopwatch()..start();
      expect(() => engine.evalSync('b'), throwsA(isA<JsExecutionOverrun>()));
      sw.stop();
      expect(calls, 1, reason: '熔断后不该再跑脚本');
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 50)));
    });

    test('预算内的求值照常返回,不动看门狗', () {
      final engine = JsEngine.withEvaluator((code) => 'ok', label: 'demo');
      expect(engine.evalSync('1+1'), 'ok');
      expect(engine.isBlown, isFalse);
      expect(JsWatchdog.instance.lastOverrun, isNull);
      expect(JsWatchdog.instance.inFlight, isNull, reason: '结束后要清掉在飞记录');
    });

    test('脚本自身抛错仍是 JsEngineException,不被误报成超时', () {
      final engine = JsEngine.withEvaluator(
          (code) => throw JsEngineException('SyntaxError'),
          label: 'demo');
      expect(() => engine.evalSync('oops'), throwsA(isA<JsEngineException>()));
      expect(engine.isBlown, isFalse);
    });
  });

  group('JsWatchdog', () {
    test('超预算会记进看门狗,能指名道姓说是哪个源', () {
      final engine =
          JsEngine.withEvaluator(_slow, label: 'yhdmp', budget: _budget);
      expect(() => engine.evalSync('bad()'), throwsA(anything));
      final last = JsWatchdog.instance.lastOverrun;
      expect(last, isNotNull);
      expect(last!.label, 'yhdmp');
    });

    test('在飞记录在求值期间存在、结束后清空', () {
      JsEvalMark? seen;
      final engine = JsEngine.withEvaluator((code) {
        seen = JsWatchdog.instance.inFlight;
        return 'ok';
      }, label: 'demo');
      engine.evalSync('someCall()');
      expect(seen, isNotNull);
      expect(seen!.label, 'demo');
      expect(seen!.codePreview, 'someCall()');
      expect(JsWatchdog.instance.inFlight, isNull);
    });
  });

  group('checkSourceHealth 分类', () {
    const meta = SourceMeta(id: 'stuck', name: '卡死源', script: 'x');

    test('脚本卡死归为 scriptStuck,而不是普通失败', () async {
      final r = await checkSourceHealth(meta, mangaBuilder: _stuckBuilder);
      expect(r.status, SourceHealthStatus.fail);
      expect(r.failure, SourceHealthFailure.scriptStuck);
    });

    test('普通失败仍是 other', () async {
      final r = await checkSourceHealth(
        meta,
        mangaBuilder: (_) => _BoomSource(),
      );
      expect(r.status, SourceHealthStatus.fail);
      expect(r.failure, SourceHealthFailure.other);
    });
  });
}
