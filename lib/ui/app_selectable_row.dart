import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import 'app_card.dart';

/// 单选项行:描边卡,选中 = accent 淡底 + accent 边 + 尾部对勾。
///
/// 「一组里选一个」的场景(后端切换、代理模式等)都走它,统一那些手搓的
/// InkWell + BoxDecoration 选择卡。
class AppSelectableRow extends StatelessWidget {
  const AppSelectableRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppCard(
      width: double.infinity,
      onTap: onTap,
      color: selected ? p.accent.withValues(alpha: 0.10) : p.surface,
      borderColor: selected ? p.accent : p.line,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 10),
          ] else if (icon != null) ...[
            Icon(icon, size: 18, color: selected ? p.accent : p.textMuted),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!,
                      style: TextStyle(color: p.textMuted, fontSize: 12)),
                ],
              ],
            ),
          ),
          if (selected)
            Icon(Icons.check_circle_rounded, size: 18, color: p.accent),
        ],
      ),
    );
  }
}
