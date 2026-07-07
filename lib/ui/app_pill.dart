import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 静态标签/徽章/角标(只读,不可点 —— 可点的是 AppFilterChip)。
///
/// 覆盖:封面来源角标、未读计数、页码、版本徽章、题材 tag、来源 chip 等。
/// 叠在图片上的用固定色(传 [fill]/[textColor]),分组内的走 palette 默认。
class AppPill extends StatelessWidget {
  const AppPill({
    super.key,
    required this.text,
    this.leadingIcon,
    this.fill,
    this.border,
    this.textColor,
    this.fontSize = 10,
    this.fontWeight = FontWeight.w700,
    this.radius = 999,
    this.padding = const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    this.maxWidth,
    this.maxLines = 1,
    this.constraints,
    this.tabularFigures = false,
  });

  /// accent 便捷构造:淡底 + 淡边 + 微亮字(状态角标/版本徽章那种)。
  factory AppPill.accent(String text, Color color,
          {double radius = 999,
          double fontSize = 10,
          EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 9, vertical: 3)}) =>
      AppPill(
        text: text,
        fill: color.withValues(alpha: 0.16),
        border: color.withValues(alpha: 0.45),
        textColor: Color.lerp(color, Colors.white, 0.25),
        radius: radius,
        fontSize: fontSize,
        padding: padding,
      );

  final String text;
  final IconData? leadingIcon;
  final Color? fill;
  final Color? border;
  final Color? textColor;
  final double fontSize;
  final FontWeight fontWeight;
  final double radius;
  final EdgeInsets padding;
  final double? maxWidth;
  final int maxLines;
  final BoxConstraints? constraints;
  final bool tabularFigures;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = textColor ?? p.textMuted;
    Widget label = Text(
      text,
      maxLines: maxLines,
      overflow: maxLines == 1 ? TextOverflow.ellipsis : TextOverflow.clip,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: fg,
        fontSize: fontSize,
        fontWeight: fontWeight,
        height: 1.0,
        fontFeatures:
            tabularFigures ? const [FontFeature.tabularFigures()] : null,
      ),
    );
    if (leadingIcon != null) {
      label = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(leadingIcon, size: fontSize + 3, color: fg),
          const SizedBox(width: 4),
          Flexible(child: label),
        ],
      );
    }
    return Container(
      alignment: Alignment.center,
      constraints:
          maxWidth != null ? BoxConstraints(maxWidth: maxWidth!) : constraints,
      padding: padding,
      decoration: BoxDecoration(
        color: fill ?? p.surface,
        borderRadius: BorderRadius.circular(radius),
        border: border != null ? Border.all(color: border!) : null,
      ),
      child: label,
    );
  }
}
