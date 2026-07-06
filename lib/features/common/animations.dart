import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/library_store.dart';

/// 所有入场动画组件的约定:控制器初始值取 `LibraryStore.animationsEnabled ? 0 : 1`,
/// 这样全局「开启动画」关掉时,`..forward()` 从 1 出发即刻完成、渲染成静态,零 tick。
/// 连续反馈型(如 [Pressable])则在 build 里读该静态量决定是否动。
///
/// 首次构建时「随机从下飞入」+ 淡入。给网格卡入场加错落的层次感。
/// 飞入距离 + 起始延迟由 [seed](传 manga.id)稳定派生 —— 同一张卡每次 rebuild
/// 都得到相同的距离/延迟,不会在动画途中抖动重掷。惰性网格里卡片滚出再滚回会重演
/// (与 [FadeSlideIn] 一致的「滚到哪亮到哪」)。
class FlyInUp extends StatefulWidget {
  const FlyInUp({
    super.key,
    required this.child,
    required this.seed,
    this.duration = const Duration(milliseconds: 420),
    this.minOffset = 24,
    this.maxOffset = 42,
    this.maxDelayMs = 140,
  });

  final Widget child;
  final String seed;
  final Duration duration;
  final double minOffset;
  final double maxOffset;
  final int maxDelayMs;

  @override
  State<FlyInUp> createState() => _FlyInUpState();
}

class _FlyInUpState extends State<FlyInUp> with SingleTickerProviderStateMixin {
  late final math.Random _rng = math.Random(_seedInt(widget.seed));
  // 一次性掷定,存字段 → build 里绝不重掷。
  late final double _offset = widget.minOffset +
      _rng.nextDouble() * (widget.maxOffset - widget.minOffset);
  late final int _delayMs = (_rng.nextDouble() * widget.maxDelayMs).round();

  // 把延迟塞进曲线前段(Interval),省一个可能泄漏的 Timer。
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration + Duration(milliseconds: widget.maxDelayMs),
    value: LibraryStore.scrollAnimationsEnabled ? 0.0 : 1.0, // 关滚动动画=直接到位
  )..forward();

  late final Animation<double> _a = CurvedAnimation(
    parent: _c,
    curve: Interval(
      _delayMs / (widget.duration.inMilliseconds + widget.maxDelayMs),
      1.0,
      curve: Curves.easeOutCubic,
    ),
  );

  int _seedInt(String s) {
    var h = 0;
    for (var i = 0; i < s.length; i++) {
      h = (h * 31 + s.codeUnitAt(i)) & 0x7fffffff;
    }
    return h;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        builder: (_, child) {
          final t = _a.value;
          return Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, (1 - t) * _offset),
              child: child,
            ),
          );
        },
        child: widget.child,
      );
}

/// 首次构建时淡入 + 轻微位移滑入。给网格卡/列表项入场加层次感。
/// (惰性列表里每项滚入视野时才 build,所以自然形成「滚到哪亮到哪」的效果。)
/// [offset] 垂直起始偏移,[dx] 水平起始偏移(正=从右侧滑入),
/// [delayMs] 入场前延迟(按下标传入可做错落 stagger)。
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 300),
    this.offset = 12,
    this.dx = 0,
    this.delayMs = 0,
  });

  final Widget child;
  final Duration duration;
  final double offset;
  final double dx;
  final int delayMs;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  // 把延迟塞进曲线前段(Interval),省一个 Timer;delayMs=0 时退化为整段曲线。
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration + Duration(milliseconds: widget.delayMs),
    value: LibraryStore.scrollAnimationsEnabled ? 0.0 : 1.0,
  )..forward();
  late final Animation<double> _a = CurvedAnimation(
    parent: _c,
    curve: Interval(
      widget.delayMs / (widget.duration.inMilliseconds + widget.delayMs),
      1.0,
      curve: Curves.easeOutCubic,
    ),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        builder: (_, child) {
          final t = _a.value;
          return Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(widget.dx * (1 - t), widget.offset * (1 - t)),
              child: child,
            ),
          );
        },
        child: widget.child,
      );
}

/// 按下轻微缩小、松开回弹 —— 给卡片/按钮加触感。桌面端还带指针悬停微亮。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.96,
    this.hoverElevate = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  /// 桌面端鼠标悬停时轻微放大(网格封面用)。
  final bool hoverElevate;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final anim = LibraryStore.animationsEnabled;
    var scale = 1.0;
    if (anim && _down) {
      scale = widget.scale;
    } else if (anim && _hover && widget.hoverElevate) {
      scale = 1.03;
    }
    Widget child = AnimatedScale(
      scale: scale,
      duration:
          anim ? const Duration(milliseconds: 120) : Duration.zero,
      curve: Curves.easeOut,
      child: widget.child,
    );
    if (widget.hoverElevate) {
      child = MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: child,
      );
    }
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      child: child,
    );
  }
}
