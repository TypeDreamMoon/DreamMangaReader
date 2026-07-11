import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/bangumi/bangumi_api.dart';
import '../../ui/ui.dart';

/// 可复用的 Bangumi 评分卡:加载中 / 未匹配(可手动搜索)/ 已匹配(评分·星级·排名·
/// 制作信息·题材 tag·可展开简介·在 bgm.tv 打开)。漫画详情页原为内联实现,这里抽成
/// 通用组件供番剧详情页复用。评分/简介为空则由调用方决定是否渲染本卡。
class BangumiCard extends StatefulWidget {
  const BangumiCard({
    super.key,
    required this.loading,
    required this.info,
    this.onRematch,
  });

  final bool loading;
  final BangumiInfo? info;

  /// 手动搜索 / 重新匹配;为 null 则不显示对应按钮。
  final VoidCallback? onRematch;

  @override
  State<BangumiCard> createState() => _BangumiCardState();
}

class _BangumiCardState extends State<BangumiCard> {
  bool _summaryExpanded = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget shell(Widget child) => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(context.radius),
            border: Border.all(color: p.line),
          ),
          child: child,
        );

    if (widget.loading) {
      return shell(Row(
        children: [
          SizedBox(
              width: 15,
              height: 15,
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: p.bangumi)),
          const SizedBox(width: 10),
          Text('匹配 Bangumi 中…',
              style: TextStyle(color: p.textMuted, fontSize: 12)),
        ],
      ));
    }

    final b = widget.info;
    if (b == null) {
      return shell(Row(
        children: [
          Icon(Icons.search_off_rounded, size: 18, color: p.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text('未匹配到 Bangumi 条目',
                style: TextStyle(color: p.textMuted, fontSize: 12.5)),
          ),
          if (widget.onRematch != null)
            TextButton.icon(
              onPressed: widget.onRematch,
              icon: const Icon(Icons.search_rounded, size: 16),
              label: const Text('手动搜索'),
              style: TextButton.styleFrom(
                  foregroundColor: p.bangumi,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            ),
        ],
      ));
    }

    final filled = (b.score / 2).floor();
    final half = (b.score / 2 - filled) >= 0.5;
    final metaBits = <String>[
      if (b.date.isNotEmpty) b.date,
      if (b.eps > 0) '${b.eps} 话',
    ];
    return shell(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Bangumi',
                style: TextStyle(
                    color: p.bangumi,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0)),
            const Spacer(),
            if (widget.onRematch != null)
              _icon(p, Icons.search_rounded, '重新匹配', widget.onRematch!),
            const SizedBox(width: 2),
            _icon(p, Icons.open_in_new_rounded, '在 Bangumi 打开',
                () => launchUrl(Uri.parse(b.url),
                    mode: LaunchMode.externalApplication)),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(b.score.toStringAsFixed(1),
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    height: 1.0)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    for (var i = 0; i < 5; i++)
                      Icon(
                          i < filled
                              ? Icons.star_rounded
                              : (i == filled && half
                                  ? Icons.star_half_rounded
                                  : Icons.star_border_rounded),
                          size: 15,
                          color: p.bangumi),
                  ]),
                  const SizedBox(height: 4),
                  Text('${b.rank > 0 ? '#${b.rank} · ' : ''}${b.votesLabel}',
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(b.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: p.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
        if (b.nameOrig.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(b.nameOrig,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textMuted, fontSize: 11)),
          ),
        if (metaBits.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(metaBits.join('  ·  '),
              style: TextStyle(color: p.textMuted, fontSize: 11)),
        ],
        if (b.infobox.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final row in b.infobox.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(row.$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textMuted, fontSize: 11)),
                  ),
                  Expanded(
                    child: Text(row.$2,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textPrimary, fontSize: 11)),
                  ),
                ],
              ),
            ),
        ],
        if (b.tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in b.tags.take(8))
                AppPill(
                  text: t,
                  fill: p.bangumi.withValues(alpha: 0.10),
                  textColor: Color.lerp(p.bangumi, Colors.white, 0.3),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  radius: 6,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                ),
            ],
          ),
        ],
        if (b.summary.isNotEmpty) ...[
          const SizedBox(height: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _summaryExpanded = !_summaryExpanded),
            child: AnimatedSize(
              duration: LibraryStore.animationsEnabled
                  ? const Duration(milliseconds: 220)
                  : Duration.zero,
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: Text(b.summary,
                  maxLines: _summaryExpanded ? null : 3,
                  overflow: _summaryExpanded
                      ? TextOverflow.clip
                      : TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.textMuted, fontSize: 11.5, height: 1.5)),
            ),
          ),
        ],
      ],
    ));
  }

  Widget _icon(AppPalette p, IconData icon, String tip, VoidCallback onTap) =>
      IconButton(
        onPressed: onTap,
        tooltip: tip,
        icon: Icon(icon, size: 16),
        color: p.textMuted,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      );
}
