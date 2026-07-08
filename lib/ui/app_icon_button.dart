import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 方形描边图标按钮(带激活态)。详情页的操作键排、工具条那种「小方块按钮」走它。
///
/// 非激活:elevated 底 + line 边;激活:accent 淡底 + accent 边 + accent 图标。
/// onTap 为空 = 禁用观感(灰图标)。
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.active = false,
    this.accent,
    this.size = 46,
    this.iconSize = 20,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final Color? accent;
  final double size;
  final double iconSize;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ac = accent ?? p.accent;
    final fg = active
        ? ac
        : (onTap == null ? p.textMuted : p.textPrimary);
    final btn = Material(
      color: active ? ac.withValues(alpha: 0.16) : p.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.radius),
        side: BorderSide(color: active ? ac : p.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: iconSize, color: fg),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}
