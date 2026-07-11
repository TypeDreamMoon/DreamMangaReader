import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
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
  final Set<LogEntry> _expanded = {}; // 展开(看完整 detail)的条目(按对象身份)

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: Text(context.l10n.log_title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          IconButton(
            tooltip: context.l10n.log_copyAll,
            onPressed: _copyAll,
            icon: const Icon(Icons.copy_all_rounded),
          ),
          IconButton(
            tooltip: context.l10n.disc_clear,
            onPressed: () {
              AppLog.i.clear();
              setState(_expanded.clear);
              showAppNotify(context, context.l10n.log_cleared,
                  kind: AppNotifyKind.success);
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
                  builder: (_, __) => Column(
                    children: [
                      _countHint(p),
                      Expanded(child: _list(p)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _countHint(AppPalette p) {
    final total = AppLog.i.length;
    if (total == 0) return const SizedBox.shrink();
    // 有筛选时显示「筛出 X / 共 Y」,避免计数与筛后列表对不上。
    final shown = _filter == null
        ? total
        : AppLog.i.entries.where((e) => e.level == _filter).length;
    final countText = _filter == null
        ? context.l10n.log_countTotal(total)
        : context.l10n.log_countFiltered(shown, total);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Text(countText,
              style: TextStyle(color: p.textMuted, fontSize: 11)),
          const SizedBox(width: 8),
          Text(context.l10n.log_tapDetailHint,
              style: TextStyle(
                  color: p.textMuted.withValues(alpha: 0.7), fontSize: 11)),
        ],
      ),
    );
  }

  Widget _filterBar(AppPalette p) => SizedBox(
        height: 44,
        child: AppScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          children: [
            _chip(p, context.l10n.disc_statusAll, null),
            _chip(p, context.l10n.log_lvlInfo, LogLevel.info),
            _chip(p, context.l10n.log_lvlSuccess, LogLevel.success),
            _chip(p, context.l10n.log_lvlWarning, LogLevel.warning),
            _chip(p, context.l10n.log_lvlError, LogLevel.error),
            _chip(p, context.l10n.log_lvlDebug, LogLevel.debug),
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
    // 环形缓冲淘汰旧条目后,顺手把 _expanded 里已失效的引用清掉(防长期挂着占内存)。
    if (_expanded.isNotEmpty) {
      final live = all.toSet();
      _expanded.retainWhere(live.contains);
    }
    final items = (_filter == null
            ? all
            : all.where((e) => e.level == _filter).toList())
        .reversed
        .toList(); // 最新在上
    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.receipt_long_rounded,
        title: all.isEmpty
            ? context.l10n.log_emptyTitle
            : context.l10n.log_emptyLevelTitle,
        message: all.isEmpty ? context.l10n.log_emptyMsg : null,
      );
    }
    return AppScrollView.separated(
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
    final hasDetail = e.detail != null && e.detail!.isNotEmpty;
    final expanded = _expanded.contains(e);
    // 标题行 + 收起态的一行详情预览:点它整体展开/收起(展开态的可选中详情在外面,
    // 不裹进这个 InkWell,免得 SelectableText 的手势吞掉收起点击)。
    final header = InkWell(
      onTap: hasDetail
          ? () => setState(() {
                if (!_expanded.remove(e)) _expanded.add(e);
              })
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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
                // 消息(收起态最多 3 行,展开态全显)
                Expanded(
                  child: Text(e.message,
                      maxLines: expanded ? null : 3,
                      overflow:
                          expanded ? TextOverflow.clip : TextOverflow.ellipsis,
                      style: TextStyle(
                          color: msgColor, fontSize: 12.5, height: 1.35)),
                ),
                if (hasDetail)
                  Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: p.textMuted),
              ],
            ),
            // 收起态:一行详情预览(点整条展开看全文)。
            if (hasDetail && !expanded)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 3),
                child: Text(e.detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: p.textMuted.withValues(alpha: 0.75),
                        fontSize: 11)),
              ),
          ],
        ),
      ),
    );
    if (!hasDetail || !expanded) return header;
    // 展开态:标题行 + 可选中的完整详情(独立于 InkWell)+ 复制此条。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 2),
          child: SelectableText(e.detail!,
              style:
                  TextStyle(color: p.textMuted, fontSize: 11, height: 1.35)),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 4, bottom: 7),
          child: GestureDetector(
            onTap: () => _copyEntry(e),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.copy_rounded, size: 13, color: p.accent),
                const SizedBox(width: 4),
                Text(context.l10n.log_copyOne,
                    style: TextStyle(
                        color: p.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _copyEntry(LogEntry e) async {
    final text = '${e.timeText}  [${e.cat.label}] ${e.message}'
        '${e.detail != null && e.detail!.isNotEmpty ? '\n${e.detail}' : ''}';
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showAppNotify(context, context.l10n.log_copiedOne,
          kind: AppNotifyKind.success);
    }
  }

  Future<void> _copyAll() async {
    // 文本与条数在同一同步时刻取,避免 await 期间后台又写日志导致提示数对不上。
    final text = AppLog.i.asText();
    final n = AppLog.i.length;
    if (text.isEmpty) {
      showAppNotify(context, context.l10n.log_nothingToCopy,
          kind: AppNotifyKind.info);
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showAppNotify(context, context.l10n.log_copiedN(n),
          kind: AppNotifyKind.success);
    }
  }
}
