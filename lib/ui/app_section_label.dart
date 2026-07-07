import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 分区小标题(青碧大写微标题)。关于页/调试页的小节头都走它。
///
/// 大号分组标题(书架的板块头、设置的「竖条+尾线」）是另一种视觉,不在此列。
class AppSectionLabel extends StatelessWidget {
  const AppSectionLabel(
    this.text, {
    super.key,
    this.uppercase = true,
    this.color,
    this.fontSize = 11,
    this.fontWeight = FontWeight.w700,
    this.letterSpacing = 2,
    this.padding = EdgeInsets.zero,
  });

  final String text;
  final bool uppercase;
  final Color? color;
  final double fontSize;
  final FontWeight fontWeight;
  final double letterSpacing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: padding,
      child: Text(
        uppercase ? text.toUpperCase() : text,
        style: TextStyle(
          color: color ?? p.accent,
          fontSize: fontSize,
          fontWeight: fontWeight,
          letterSpacing: letterSpacing,
        ),
      ),
    );
  }
}
