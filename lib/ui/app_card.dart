import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 统一卡片:`surface` 底 + `line` 描边 + 圆角(跟随「控件圆角」设置)。
///
/// 全 App 的分组卡 / 信息卡 / 行卡都走它 —— 圆角、描边、内边距改一处即全局生效。
/// 用 [Material] 而非纯 [DecoratedBox],里面的 [InkWell]/[ListTile] 才有地方画水波纹。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
    this.color,
    this.radius,
    this.radiusBoost = 2,
    this.borderColor,
    this.borderWidth = 1,
    this.width,
    this.shadow,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 非空则整卡可点(带水波纹)。
  final VoidCallback? onTap;

  /// 卡片底色,默认 `palette.surface`。
  final Color? color;

  /// 圆角;null = `context.radius + radiusBoost`(跟随设置)。传常量可固定(如 12)。
  final double? radius;
  final double radiusBoost;

  /// 描边色,默认 `palette.line`;宽度默认 1。
  final Color? borderColor;
  final double borderWidth;

  /// 固定宽度(如需撑满传 `double.infinity`)。
  final double? width;

  /// 可选投影(仅个别场景,如 Logo)。
  final List<BoxShadow>? shadow;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final r = radius ?? (context.radius + radiusBoost);
    final content = Padding(padding: padding, child: child);
    Widget card = Material(
      color: color ?? p.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(r),
        side: BorderSide(color: borderColor ?? p.line, width: borderWidth),
      ),
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );
    if (shadow != null) {
      card = DecoratedBox(
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(r), boxShadow: shadow),
        child: card,
      );
    }
    if (width != null) card = SizedBox(width: width, child: card);
    return card;
  }
}
