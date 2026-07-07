import 'package:flutter/material.dart';

/// 状态圆点(可用性绿/黄/红、更新点、项目符号)。可选发光。
class AppStatusDot extends StatelessWidget {
  const AppStatusDot({
    super.key,
    required this.color,
    this.size = 10,
    this.glow = false,
  });

  final Color color;
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: glow
              ? [
                  BoxShadow(
                      color: color.withValues(alpha: 0.55),
                      blurRadius: 6,
                      spreadRadius: 1),
                ]
              : null,
        ),
      );
}
