import 'package:flutter/material.dart';

/// 加载占位:带流光(shimmer)扫过的骨架块,替代干巴巴的转圈。
/// 用固定深色(不依赖主题扩展),阅读器等深色场景直接可用、且不会因缺 palette 崩。
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = 6,
    this.baseColor,
  });

  final double? width;
  final double? height;
  final double radius;
  final Color? baseColor;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.baseColor ?? const Color(0xFF1A1F1D);
    final hi = Color.alphaBlend(Colors.white.withValues(alpha: 0.11), base);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final dx = _c.value * 2 - 1; // -1 → 1,高光带扫过
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(dx - 1, 0),
              end: Alignment(dx + 1, 0),
              colors: [base, hi, base],
              stops: const [0.35, 0.5, 0.65],
            ),
          ),
        );
      },
    );
  }
}
