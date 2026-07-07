import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 毛玻璃表面。`ClipRRect → BackdropFilter(模糊身后内容) → 半透明填充`。
///
/// **只在身后有内容(图片 / 滚动列表 / 变暗遮罩)时才用 [enabled]=true**——BackdropFilter
/// 会对「身后那一层」做一次离屏模糊 pass;若身后只是纯色背景,模糊看不出效果还白费 GPU。
/// 身后是纯色时用 [enabled]=false:只保留半透明填充(玻璃观感),不加模糊。
///
/// 填充色按主题自动推导:Light 需较高不透明度保对比度;OLED 纯黑要叠一点白才有玻璃质感。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.blur = 20,
    this.padding,
    this.border,
    this.enabled = true,
    this.tint,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final Border? border;

  /// false = 不加 BackdropFilter,只做半透明填充(身后是纯色时用,省一次模糊 pass)。
  final bool enabled;

  /// 覆盖默认按主题推导的填充色。
  final Color? tint;

  /// 按主题推导毛玻璃填充色。
  static Color glassTint(AppPalette p) {
    if (p.brightness == Brightness.light) {
      // 白底:高亮内容会透上来压低对比度 → 填充不透明度要高些,靠边框+高光找玻璃感。
      return p.surface.withValues(alpha: 0.74);
    }
    final isOled = p.background.computeLuminance() < 0.01;
    if (isOled) {
      // 纯黑上先叠一点白再半透明,否则玻璃看着就是一块黑、没有层次。
      return Color.alphaBlend(
              Colors.white.withValues(alpha: 0.05), p.surface)
          .withValues(alpha: 0.58);
    }
    return p.surface.withValues(alpha: 0.64);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final radius = borderRadius ?? BorderRadius.zero;
    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: tint ?? glassTint(p),
        borderRadius: radius,
        border: border,
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
    if (!enabled) {
      return ClipRRect(borderRadius: radius, child: content);
    }
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: content,
      ),
    );
  }
}
