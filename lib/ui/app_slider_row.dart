import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 统一滑块行:前导图标 + 标签 + `Expanded(Slider)` + 数值文本。
///
/// 设置页与阅读设置里的「图标 + 标签 + 滑条 + 数值」都走它。
/// 前导/尾部可整块覆盖(阅读器亮度行:月亮图标当前导、太阳当尾部、无数值文本)。
class AppSliderRow extends StatelessWidget {
  const AppSliderRow({
    super.key,
    this.icon,
    this.label,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.onChanged,
    this.pct = false,
    this.valueFormat,
    this.showValueText = true,
    this.valueWidth = 40,
    this.valueFontSize = 13,
    this.iconColor,
    this.leading,
    this.trailing,
  });

  final IconData? icon;
  final Color? iconColor;
  final String? label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;

  /// true 时数值按百分比显示(0–1 → 0–100%)。[valueFormat] 优先。
  final bool pct;
  final String Function(double)? valueFormat;
  final bool showValueText;
  final double valueWidth;
  final double valueFontSize;

  /// 覆盖前导 / 尾部整块(如亮度行的月亮/太阳)。
  final Widget? leading;
  final Widget? trailing;

  String _fmt(double v) =>
      valueFormat?.call(v) ?? (pct ? '${(v * 100).round()}%' : v.round().toString());

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        if (leading != null)
          leading!
        else if (icon != null) ...[
          Icon(icon, size: 18, color: iconColor ?? p.accent),
          const SizedBox(width: 8),
        ],
        if (label != null)
          Text(label!,
              style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: _fmt(value),
            onChanged: onChanged,
          ),
        ),
        if (trailing != null)
          trailing!
        else if (showValueText)
          SizedBox(
            width: valueWidth,
            child: Text(_fmt(value),
                textAlign: TextAlign.end,
                style: TextStyle(color: p.textMuted, fontSize: valueFontSize)),
          ),
      ],
    );
  }
}
