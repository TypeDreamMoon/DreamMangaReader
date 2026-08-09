import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';

/// 源没给简介 → 退回备用来源(漫画/番剧退到 Bangumi 条目简介)。
/// 返回正文与「是否用了备用来源」(后者驱动标题旁的「· 来自 Bangumi」)。
({String text, bool fromFallback}) resolveSynopsis(
    String? primary, String? fallback) {
  final own = (primary ?? '').trim();
  if (own.isNotEmpty) return (text: own, fromFallback: false);
  final alt = (fallback ?? '').trim();
  return (text: alt, fromFallback: alt.isNotEmpty);
}

/// 详情页的简介卡:accent 小标题 + 可展开正文 + 展开/收起。
///
/// 三个详情页原本各写一份,漫画与番剧的除了局部变量名之外一字不差。
/// 小说那份的差异是真差异(正文更长、没有 Bangumi 备用来源),所以留成参数,
/// 而不是把它拉平成漫画的口径。
class DetailSynopsis extends StatelessWidget {
  const DetailSynopsis({
    super.key,
    required this.text,
    required this.accent,
    required this.expanded,
    required this.onToggle,
    this.sourceNote,
    this.collapsedLines = 4,
    this.expandThreshold = 90,
    this.textKey,
  });

  final String text;
  final Color accent;
  final bool expanded;
  final VoidCallback onToggle;

  /// 标题旁的来源注记(如「· 来自 Bangumi」);null = 不显示。
  final String? sourceNote;

  /// 收起时显示几行。
  final int collapsedLines;

  /// 正文超过多少字才给「展开全部」。
  final int expandThreshold;

  /// 正文的定位 Key(测试用)。
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    final canExpand = text.runes.length > expandThreshold;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(context.radius),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(context.l10n.detail_synopsis,
                    style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0)),
                if (sourceNote != null) ...[
                  const SizedBox(width: 6),
                  Text(sourceNote!,
                      style: TextStyle(color: p.textMuted, fontSize: 10.5)),
                ],
              ],
            ),
            const SizedBox(height: 8),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: Text(
                text,
                key: textKey,
                maxLines: expanded ? null : collapsedLines,
                overflow:
                    expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: TextStyle(
                    color: p.textPrimary.withValues(alpha: 0.82),
                    fontSize: 13,
                    height: 1.55),
              ),
            ),
            if (canExpand) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: onToggle,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                        expanded
                            ? context.l10n.detail_collapse
                            : context.l10n.detail_expandAll,
                        style: TextStyle(
                            color: accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.keyboard_arrow_down_rounded,
                          color: accent, size: 18),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
