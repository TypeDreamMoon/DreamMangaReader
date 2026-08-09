import 'package:flutter/material.dart';

import '../app/library_store.dart';

/// 按下轻微缩小、松开回弹 —— 给卡片/按钮加触感。桌面端还带指针悬停微亮。
///
/// 全 App 的点按反馈都走它(而非 Material 水波纹),所以住在设计系统层:
/// [AppIconButton] 这类 `ui/` 组件也要用,不能反过来依赖 `features/`。
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
      duration: anim ? const Duration(milliseconds: 120) : Duration.zero,
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
