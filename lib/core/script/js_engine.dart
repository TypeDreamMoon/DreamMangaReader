import 'package:flutter_js/flutter_js.dart';

/// 对 flutter_js(非 Web 平台为 QuickJS)的最小封装。
///
/// P0 只验证"能在 Android + Windows 上真正跑 JS";后续会在这里注入
/// HostApi(http / html / crypto),把它变成承载脚本源(复用参考项目 TS 插件)的
/// `ScriptSourceRuntime`——脚本调用宿主能力、宿主执行 I/O。
class JsEngine {
  JsEngine() : _rt = getJavascriptRuntime();

  final JavascriptRuntime _rt;
  bool _disposed = false;

  /// 同步求值,返回字符串结果;JS 抛错时抛 [JsEngineException]。
  String evalSync(String code) {
    if (_disposed) throw StateError('JsEngine 已释放');
    final r = _rt.evaluate(code);
    if (r.isError) {
      throw JsEngineException(r.stringResult);
    }
    return r.stringResult;
  }

  /// 注册一个同步宿主通道:JS 侧 `sendMessage('<channel>', msg)` 调用它,
  /// 该 handler 的返回值即 `sendMessage` 的返回值(约定双方用 JSON 字符串)。
  /// 这是把 Dart 原生能力(HTML 解析、crypto 等)暴露给脚本源的机制。
  void onMessage(
          String channel, dynamic Function(dynamic message) handler) =>
      _rt.onMessage(channel, handler);

  /// 幂等:构造失败时由 [ScriptSource] 就地回收,调用方若再兜一次 dispose
  /// 不该二次释放原生运行时。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _rt.dispose();
  }
}

class JsEngineException implements Exception {
  JsEngineException(this.message);

  final String message;

  @override
  String toString() => 'JsEngineException: $message';
}
