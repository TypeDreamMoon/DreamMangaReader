import 'package:flutter_js/flutter_js.dart';
import 'package:meta/meta.dart';

import '../log/app_log.dart';

/// 对 flutter_js(非 Web 平台为 QuickJS)的最小封装。
///
/// P0 只验证"能在 Android + Windows 上真正跑 JS";后续会在这里注入
/// HostApi(http / html / crypto),把它变成承载脚本源(复用参考项目 TS 插件)的
/// `ScriptSourceRuntime`——脚本调用宿主能力、宿主执行 I/O。
///
/// ## 执行时长与看门狗
///
/// [evalSync] 在**调用方 isolate 内同步**执行远程脚本。flutter_js 0.8.7 没有把
/// QuickJS 的 `JS_SetInterruptHandler` 暴露出来(`quickjs_c_bridge` 的导出表里
/// 只有 jsEval / jsNewRuntime / jsSetMaxStackSize… 没有任何 interrupt 相关符号;
/// `QuickJsRuntime2(timeout:)` 那个参数实测也打不断一个 `while(true)`),
/// 所以宿主**没有办法从外部掐断一次正在跑的求值**——
/// 这里能做的是把每次求值算进预算,超预算就:
///
/// 1. 把这次求值判为失败(抛 [JsExecutionOverrun]),
/// 2. **熔断这个引擎**:之后每次 [evalSync] 立刻抛同一个错,不再给它第二次机会,
/// 3. 记进 [JsWatchdog] 与运行日志,让源管理页能指名道姓地说是哪个源。
///
/// 效果:退化正则、O(n²) 解析这类「很慢但会结束」的脚本只会卡一次,
/// 之后该源被判不健康;**真正的 `while(true)` 仍然会永久占住这个 isolate**——
/// 这是 flutter_js 当前能力的硬边界,只有把执行搬进独立 isolate 才能根治
/// (需要把 ScriptSource 的同步 prepare/handle 全改成异步,不在本次修复范围内)。
class JsEngine {
  JsEngine({this.label = 'script', this.budget = defaultBudget})
      : _rt = getJavascriptRuntime(),
        _evaluator = null;

  /// 仅供测试:用一个假的求值器代替 QuickJS(测试进程里没有原生库可加载)。
  /// 求值失败请让它抛 [JsEngineException],与真实实现的语义一致。
  @visibleForTesting
  JsEngine.withEvaluator(
    String Function(String code) evaluator, {
    this.label = 'script',
    this.budget = defaultBudget,
  })  : _rt = null,
        _evaluator = evaluator;

  bool _disposed = false;

  /// 单次同步求值的时长预算。脚本的 parse / prepare / handle 都是纯计算,
  /// 正常在毫秒级;给到 10s 是为了在最慢的低端机上也不误伤。
  static const defaultBudget = Duration(seconds: 10);

  /// 这个引擎属于谁(通常是源 id),用于日志与 UI 提示。
  final String label;

  final Duration budget;

  final JavascriptRuntime? _rt;
  final String Function(String code)? _evaluator;

  JsExecutionOverrun? _overrun;

  /// 这个引擎是否已因超预算被熔断。
  bool get isBlown => _overrun != null;

  /// 熔断原因(未熔断为 null)。
  JsExecutionOverrun? get overrun => _overrun;

  /// 同步求值,返回字符串结果;JS 抛错时抛 [JsEngineException];
  /// 超出 [budget](或引擎已熔断)时抛 [JsExecutionOverrun]。
  String evalSync(String code) {
    if (_disposed) throw StateError('JsEngine 已释放');
    final blown = _overrun;
    if (blown != null) throw blown; // 熔断:别再冻第二次
    final sw = Stopwatch()..start();
    JsWatchdog.instance.begin(label, code);
    String? value;
    Object? failure;
    try {
      value = _rawEval(code);
    } catch (e) {
      failure = e;
    } finally {
      sw.stop();
      JsWatchdog.instance.end();
      if (sw.elapsed > budget) {
        final over = JsExecutionOverrun(
          label: label,
          elapsed: sw.elapsed,
          budget: budget,
          code: code,
        );
        _overrun = over;
        JsWatchdog.instance.record(over);
      }
    }
    final over = _overrun;
    if (over != null) throw over; // 超预算优先:结果再对也不值得留着这个源
    if (failure != null) throw failure;
    return value!;
  }

  String _rawEval(String code) {
    final evaluator = _evaluator;
    if (evaluator != null) return evaluator(code);
    final r = _rt!.evaluate(code);
    if (r.isError) throw JsEngineException(r.stringResult);
    return r.stringResult;
  }

  /// 注册一个同步宿主通道:JS 侧 `sendMessage('<channel>', msg)` 调用它,
  /// 该 handler 的返回值即 `sendMessage` 的返回值(约定双方用 JSON 字符串)。
  /// 这是把 Dart 原生能力(HTML 解析、crypto 等)暴露给脚本源的机制。
  void onMessage(
          String channel, dynamic Function(dynamic message) handler) =>
      _rt?.onMessage(channel, handler);

  /// 幂等:构造失败时由 [ScriptSource] 就地回收,调用方若再兜一次 dispose
  /// 不该二次释放原生运行时。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _rt?.dispose();
  }
}

class JsEngineException implements Exception {
  JsEngineException(this.message);

  final String message;

  @override
  String toString() => 'JsEngineException: $message';
}

/// 一次求值吃掉了超过预算的时间。带上是哪个源、跑了多久、跑的是哪段代码,
/// UI 才能给出「××源的脚本卡住了,已停用」这种能行动的提示。
@immutable
class JsExecutionOverrun implements Exception {
  JsExecutionOverrun({
    required this.label,
    required this.elapsed,
    required this.budget,
    String code = '',
  }) : codePreview = previewOf(code);

  /// 出问题的引擎标签(通常是源 id)。
  final String label;

  final Duration elapsed;
  final Duration budget;

  /// 卡住的那段脚本的开头,便于定位是 parse 还是某个 prepare/handle。
  final String codePreview;

  /// 把一段脚本压成单行摘要(日志/提示用)。
  static String previewOf(String code) {
    final one = code.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 120 ? one : '${one.substring(0, 119)}…';
  }

  @override
  String toString() => 'JsExecutionOverrun($label): '
      '${elapsed.inMilliseconds}ms > ${budget.inMilliseconds}ms · $codePreview';
}

/// 正在执行的一次求值。[JsEngine.evalSync] 期间 isolate 被占住、任何 Timer 都跑不了,
/// 所以这条记录**当场读不到**——它的用处是求值结束之后,
/// 能回答「刚才是谁把界面卡住的」。
@immutable
class JsEvalMark {
  const JsEvalMark(this.label, this.codePreview, this.startedAt);

  final String label;
  final String codePreview;
  final DateTime startedAt;
}

/// 脚本执行看门狗:全局记录「当前在跑什么」「上一次超预算的是谁」。
class JsWatchdog {
  JsWatchdog._();

  static final JsWatchdog instance = JsWatchdog._();

  JsEvalMark? _inFlight;
  JsExecutionOverrun? _lastOverrun;

  /// 正在执行的求值(没有则为 null)。
  JsEvalMark? get inFlight => _inFlight;

  /// 最近一次超预算的求值。
  JsExecutionOverrun? get lastOverrun => _lastOverrun;

  void begin(String label, String code) {
    _inFlight =
        JsEvalMark(label, JsExecutionOverrun.previewOf(code), DateTime.now());
  }

  void end() => _inFlight = null;

  void record(JsExecutionOverrun overrun) {
    _lastOverrun = overrun;
    AppLog.i.err(
      LogCat.source,
      '脚本执行超时 · ${overrun.label} · ${overrun.elapsed.inMilliseconds}ms',
      detail: '$overrun',
    );
  }

  /// 仅供测试:清空看门狗状态。
  @visibleForTesting
  void reset() {
    _inFlight = null;
    _lastOverrun = null;
  }
}
