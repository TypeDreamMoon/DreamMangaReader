import 'package:flutter/material.dart';

import '../app/library_store.dart' show LibraryStore;
import '../app/theme/app_colors.dart';
import 'pressable.dart';

/// 方形描边图标按钮(带激活态)。详情页的操作键排、工具条那种「小方块按钮」走它。
///
/// 非激活:elevated 底 + line 边;激活:accent 淡底 + accent 边 + accent 图标。
/// [onTap] 为空 = 禁用观感(灰图标)。图标换新(收藏 ♥↔♡)时缩放弹一下。
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.active = false,
    this.accent,
    this.size = 46,
    this.iconSize = 20,
    this.radius = 12,
    this.tooltip,
    this.buttonKey,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final Color? accent;
  final double size;
  final double iconSize;
  final double radius;
  final String? tooltip;

  /// 按钮本体的 Key(测试定位用;不用 [key] 是因为那个会落在 Tooltip 外层)。
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ac = accent ?? p.accent;
    final fg = active ? ac : (onTap == null ? p.textMuted : p.textPrimary);
    final duration = LibraryStore.animationsEnabled
        ? const Duration(milliseconds: 220)
        : Duration.zero;
    Widget button = Pressable(
      key: buttonKey,
      onTap: onTap,
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOut,
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: active ? ac.withValues(alpha: 0.16) : p.elevated,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: active ? ac : p.line),
        ),
        // 图标切换(如收藏 ♥↔♡)带缩放弹一下。
        child: AnimatedSwitcher(
          duration: duration,
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(icon,
              key: ValueKey('$icon$active'), color: fg, size: iconSize),
        ),
      ),
    );
    if (tooltip != null) button = Tooltip(message: tooltip!, child: button);
    return button;
  }
}
