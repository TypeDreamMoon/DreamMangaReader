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

/// 一条日志。
class LogEntry {
  LogEntry(this.time, this.cat, this.level, this.message);
  final DateTime time;
  final LogCat cat;
  final LogLevel level;
  final String message;

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

  void log(LogCat cat, String message, {LogLevel level = LogLevel.info}) {
    _entries.add(LogEntry(DateTime.now(), cat, level, message));
    if (_entries.length > _max) {
      _entries.removeRange(0, _entries.length - _max);
    }
    _notifySafe();
  }

  // 便捷入口(级别 = 颜色)。注意单例是 [i],故信息级方法叫 [info](别用 i)。
  void debug(LogCat c, String m) => log(c, m, level: LogLevel.debug);
  void info(LogCat c, String m) => log(c, m, level: LogLevel.info);
  void success(LogCat c, String m) => log(c, m, level: LogLevel.success);
  void warn(LogCat c, String m) => log(c, m, level: LogLevel.warning);
  void err(LogCat c, String m) => log(c, m, level: LogLevel.error);

  void clear() {
    _entries.clear();
    _notifySafe();
  }

  /// 导出为纯文本(复制/分享用)。
  String asText() => _entries
      .map((e) => '${e.timeText}  [${e.cat.label}] ${e.message}')
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
