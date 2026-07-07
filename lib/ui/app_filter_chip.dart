import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 可点的筛选/切换 chip(选中=淡 accent 底 + accent 边)。发现页筛选、板块切换用。
/// 与静态只读的 AppPill 刻意分开。
class AppFilterChip extends StatelessWidget {
  const AppFilterChip({
    super.key,
    required this.label,
    this.icon,
    required this.selected,
    required this.onTap,
    this.radius,
    this.height,
    this.unselectedTextColor,
    this.borderWidth = 1.5,
    this.fontSize = 13,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  final double? radius;
  final double? height;
  final Color? unselectedTextColor;
  final double borderWidth;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final r = radius ?? context.radius;
    final fg = selected ? p.accent : (unselectedTextColor ?? p.textPrimary);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: height,
        alignment: height != null ? Alignment.center : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? p.accent.withValues(alpha: 0.16) : p.surface,
          borderRadius: BorderRadius.circular(r),
          border: Border.all(
              color: selected ? p.accent : p.line, width: borderWidth),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 5),
            ],
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 160),
              style: TextStyle(
                  color: fg,
                  fontSize: fontSize,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
