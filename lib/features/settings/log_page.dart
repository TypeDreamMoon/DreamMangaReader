import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../core/log/app_log.dart';
import '../../ui/ui.dart';

/// 运行日志页:实时展示本次启动以来记录的动作(源/漫画/下载/同步/更新…),
/// 按级别上色、可按级别筛选、可一键复制或清空。日志随 App 重启自动清空。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  LogLevel? _filter; // null = 全部级别

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: const Text('运行日志',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          IconButton(
            tooltip: '复制全部',
            onPressed: _copyAll,
            icon: const Icon(Icons.copy_all_rounded),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: () {
              AppLog.i.clear();
              showAppNotify(context, '已清空日志', kind: AppNotifyKind.success);
            },
            icon: const Icon(Icons.delete_sweep_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: EntranceSlide(
        begin: const Offset(0, 0.06),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: Column(
            children: [
              _filterBar(p),
              Expanded(
                child: AnimatedBuilder(
                  animation: AppLog.i,
                  builder: (_, __) => _list(p),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterBar(AppPalette p) => SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          children: [
            _chip(p, '全部', null),
            _chip(p, '信息', LogLevel.info),
            _chip(p, '成功', LogLevel.success),
            _chip(p, '警告', LogLevel.warning),
            _chip(p, '错误', LogLevel.error),
            _chip(p, '调试', LogLevel.debug),
          ],
        ),
      );

  Widget _chip(AppPalette p, String label, LogLevel? level) {
    final sel = _filter == level;
    final tone = level == null ? p.accent : logLevelColor(level, p);
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
      child: GestureDetector(
        onTap: () => setState(() => _filter = level),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: sel ? tone.withValues(alpha: 0.16) : p.surface,
            borderRadius: BorderRadius.circular(context.radius),
            border: Border.all(color: sel ? tone : p.line, width: sel ? 1.5 : 1),
          ),
          child: Text(label,
              style: TextStyle(
                  color: sel ? tone : p.textMuted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _list(AppPalette p) {
    final all = AppLog.i.entries;
    final items = (_filter == null
            ? all
            : all.where((e) => e.level == _filter).toList())
        .reversed
        .toList(); // 最新在上
    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.receipt_long_rounded,
        title: all.isEmpty ? '暂无日志' : '该级别下暂无日志',
        message:
            all.isEmpty ? '各类动作(源 / 漫画 / 下载 / 同步…)会记录在这里' : null,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 40),
      itemCount: items.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: p.line.withValues(alpha: 0.5)),
      itemBuilder: (_, idx) => _row(p, items[idx]),
    );
  }

  Widget _row(AppPalette p, LogEntry e) {
    final lvl = logLevelColor(e.level, p);
    // 警告/错误整行文字染色,信息/成功/调试用主文字,靠圆点与分类标区分。
    final msgColor = switch (e.level) {
      LogLevel.error => p.statusFail,
      LogLevel.warning => p.statusWarn,
      _ => p.textPrimary,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 级别圆点
          Container(
            margin: const EdgeInsets.only(top: 4, right: 8),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: lvl, shape: BoxShape.circle),
          ),
          // 时间
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(e.timeText,
                style: TextStyle(
                    color: p.textMuted,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          // 分类标(分类色)
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: e.cat.color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: e.cat.color.withValues(alpha: 0.45)),
            ),
            child: Text(e.cat.label,
                style: TextStyle(
                    color: e.cat.color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700)),
          ),
          // 消息
          Expanded(
            child: Text(e.message,
                style: TextStyle(
                    color: msgColor, fontSize: 12.5, height: 1.35)),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAll() async {
    // 文本与条数在同一同步时刻取,避免 await 期间后台又写日志导致提示数对不上。
    final text = AppLog.i.asText();
    final n = AppLog.i.length;
    if (text.isEmpty) {
      showAppNotify(context, '暂无日志可复制', kind: AppNotifyKind.info);
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showAppNotify(context, '已复制 $n 条日志', kind: AppNotifyKind.success);
    }
  }
}
