import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 装饰性分区大标题:朱印意象的 accent 渐变竖条 + 粗体标题 + 尾部渐隐细线收尾。
///
/// 比 [AppSectionLabel](小号大写标签)更重,给「设置分组」这类需要视觉分隔的大标题用。
/// 颜色走 `context.palette`;竖条高度随 [fontSize] 等比缩放。
class AppSectionHeading extends StatelessWidget {
  const AppSectionHeading(
    this.text, {
    super.key,
    this.fontSize = 24,
    this.trailingRule = true,
    this.padding,
  });

  final String text;
  final double fontSize;

  /// 是否画尾部那道渐隐细线(false = 只留竖条 + 文字)。
  final bool trailingRule;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 朱印意象:accent 渐变小竖条,当分组标记。
        Container(
          width: 3.5,
          height: fontSize * 0.62,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [p.accent, p.accent.withValues(alpha: 0.45)],
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 9),
        Text(
          text,
          style: TextStyle(
            color: p.textPrimary,
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
            height: 1.2,
          ),
        ),
        if (trailingRule) ...[
          const SizedBox(width: 12),
          // 尾部渐隐细线,给分组收个尾。
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [p.line, p.line.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
        ],
      ],
    );
    return padding == null ? row : Padding(padding: padding!, child: row);
  }
}
