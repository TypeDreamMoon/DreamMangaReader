import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/theme/app_colors.dart';

/// 日志级别:决定条目主色(圆点/错误行文字)。
enum LogLevel { debug, info, success, warning, error }

/// 日志分类(动作类型):各自一个固定颜色,便于一眼区分是哪类动作。
enum LogCat {
  app('启动', Color(0xFF22D3BD)),
  source('源', Color(0xFF5B9DF9)),
  manga('漫画', Color(0xFFB57EDC)),
  reader('阅读', Color(0xFF7FD1E8)),
  download('下载', Color(0xFFE7B15A)),
  sync('同步', Color(0xFF9B8CFF)),
  update('更新', Color(0xFF3FB950)),
  search('搜索', Color(0xFFF09199)),
  network('网络', Color(0xFFB0BEC5));

  const LogCat(this.label, this.color);
  final String label;
  final Color color;
}

/// 一条日志。[detail] 是可选的次要长文本(完整 URL / 错误堆栈 / 参数),
/// 展示时折叠在第二行、点开可见,便于「详细」但不刷屏。
class LogEntry {
  LogEntry(this.time, this.cat, this.level, this.message, [this.detail]);
  final DateTime time;
  final LogCat cat;
  final LogLevel level;
  final String message;
  final String? detail;

  /// `HH:mm:ss.mmm`
  String get timeText {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${three(time.millisecond)}';
  }
}

/// 应用内运行日志。**内存环形缓冲**(上限 [_max] 条)——每次启动 App 是新进程,
/// 天然为空;[clear] 在 main 里再显式调一次并记「应用启动」。
///
/// 各处按动作调用 `AppLog.i.i(LogCat.x, '...')` / `.ok` / `.warn` / `.err` / `.d`;
/// 设置「运行日志」页监听本对象实时展示、可清空 / 复制。
class AppLog extends ChangeNotifier {
  AppLog._();
  static final AppLog i = AppLog._();

  static const _max = 800; // 超出丢最旧的,防无限增长
  final List<LogEntry> _entries = [];

  /// 时间升序(最旧在前);日志页按需反转成「最新在上」。
  List<LogEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;

  void log(LogCat cat, String message,
      {LogLevel level = LogLevel.info, String? detail}) {
    _entries.add(LogEntry(DateTime.now(), cat, level, message, detail));
    if (_entries.length > _max) {
      _entries.removeRange(0, _entries.length - _max);
    }
    _notifySafe();
  }

  // 便捷入口(级别 = 颜色)。注意单例是 [i],故信息级方法叫 [info](别用 i)。
  void debug(LogCat c, String m, {String? detail}) =>
      log(c, m, level: LogLevel.debug, detail: detail);
  void info(LogCat c, String m, {String? detail}) =>
      log(c, m, level: LogLevel.info, detail: detail);
  void success(LogCat c, String m, {String? detail}) =>
      log(c, m, level: LogLevel.success, detail: detail);
  void warn(LogCat c, String m, {String? detail}) =>
      log(c, m, level: LogLevel.warning, detail: detail);
  void err(LogCat c, String m, {String? detail}) =>
      log(c, m, level: LogLevel.error, detail: detail);

  void clear() {
    _entries.clear();
    _notifySafe();
  }

  /// 导出为纯文本(复制/分享用)。detail 折到缩进的次行。
  String asText() => _entries
      .map((e) => '${e.timeText}  [${e.cat.label}] ${e.message}'
          '${e.detail != null && e.detail!.isNotEmpty ? '\n              ${e.detail}' : ''}')
      .join('\n');

  // 记录点可能落在 build 期间(某些 widget 构建里触发动作)——那时 notify 会抛
  // 「setState/notify during build」。检测到构建阶段就推迟到帧后再通知。
  void _notifySafe() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }
}

/// 级别 → 颜色(取自当前主题的语义色,深/浅主题都协调)。
Color logLevelColor(LogLevel l, AppPalette p) => switch (l) {
      LogLevel.debug => p.textMuted,
      LogLevel.info => p.accent,
      LogLevel.success => p.statusOk,
      LogLevel.warning => p.statusWarn,
      LogLevel.error => p.statusFail,
    };

/// 一条网络请求日志(dio / webview 共用格式)。正常 2xx/3xx 记 debug(灰,可筛掉),
/// 4xx 记警告、5xx/0 记错误;完整 URL 折进 detail。
void logHttp(String method, String url, int status, int bytes, int ms) {
  final size = bytes >= 1024 ? '${(bytes / 1024).round()}KB' : '${bytes}B';
  final level = (status >= 500 || status == 0)
      ? LogLevel.error
      : (status >= 400 ? LogLevel.warning : LogLevel.debug);
  AppLog.i.log(LogCat.network,
      '$method ${shortUrl(url)} · $status · $size · ${ms}ms',
      level: level, detail: url);
}

/// 网络请求异常(连不上 / 超时 / 握手失败等)。
void logHttpError(String method, String url, int ms, Object err) {
  AppLog.i.err(LogCat.network, '$method ${shortUrl(url)} · 失败 · ${ms}ms',
      detail: '$url\n$err');
}

/// 去掉 scheme 与 query、超长截断,给日志主行用(完整地址进 detail)。
String shortUrl(String url) {
  var s = url.replaceFirst(RegExp(r'^https?://'), '');
  final q = s.indexOf('?');
  if (q >= 0) s = s.substring(0, q);
  return s.length > 56 ? '${s.substring(0, 55)}…' : s;
}
