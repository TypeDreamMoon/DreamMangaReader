import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import 'app_card.dart';

/// 统一「图标行 / 列表条目」:前导(图标或自定义)+ 标题(+副标题)+ 尾部。
///
/// 两种形态:
/// - 扁平 `AppListRow(...)`:无底色,放进 [AppCard] 分组卡里用(行间距/卡片留白由外层给)。
/// - 自带卡 `AppListRow.card(...)`:自己包一层 [AppCard](独立条目,如下载/历史/源行)。
///
/// `onTap` 非空且没给 `trailing` 时,自动补一个右箭头。
class AppListRow extends StatelessWidget {
  const AppListRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.titleSize = 14,
    this.titleWeight = FontWeight.w700,
    this.subtitle,
    this.subtitleColor,
    this.subtitleMaxLines = 2,
    this.trailing,
    this.onTap,
    this.showChevron,
    this.contentPadding = EdgeInsets.zero,
  })  : _card = false,
        cardPadding = EdgeInsets.zero;

  /// 自带 [AppCard] 外壳的条目(独立卡片式行)。
  const AppListRow.card({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.titleSize = 14,
    this.titleWeight = FontWeight.w700,
    this.subtitle,
    this.subtitleColor,
    this.subtitleMaxLines = 2,
    this.trailing,
    this.onTap,
    this.showChevron,
    this.cardPadding = const EdgeInsets.fromLTRB(10, 8, 10, 8),
  })  : _card = true,
        contentPadding = EdgeInsets.zero;

  final IconData? icon;

  /// 自定义前导(状态点 / 封面 / 单选圈…),与 [icon] 互斥。
  final Widget? leading;
  final String title;
  final double titleSize;
  final FontWeight titleWeight;
  final String? subtitle;
  final Color? subtitleColor;
  final int subtitleMaxLines;

  /// 尾部(开关 / 按钮 / 状态文本…)。为空且 [onTap] 非空时自动补右箭头。
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 是否显示右箭头;null = 自动(可点且无 trailing 时显示)。
  final bool? showChevron;

  /// 扁平形态下,行自身的内边距(卡片留白由外层 [AppCard] 给,通常留 0)。
  final EdgeInsetsGeometry contentPadding;

  final bool _card;
  final EdgeInsetsGeometry cardPadding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final chevron = showChevron ?? (onTap != null && trailing == null);

    final rowChildren = <Widget>[
      if (leading != null)
        leading!
      else if (icon != null)
        Icon(icon, color: p.accent, size: 18),
      if (leading != null || icon != null) const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: TextStyle(
                    color: p.textPrimary,
                    fontWeight: titleWeight,
                    fontSize: titleSize)),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!,
                  maxLines: subtitleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(color: subtitleColor ?? p.textMuted, fontSize: 12)),
            ],
          ],
        ),
      ),
      if (trailing != null) trailing!,
      if (chevron) Icon(Icons.chevron_right_rounded, color: p.textMuted),
    ];

    final row = Row(children: rowChildren);

    if (_card) {
      return AppCard(padding: cardPadding, onTap: onTap, child: row);
    }
    final padded = Padding(padding: contentPadding, child: row);
    return onTap == null
        ? padded
        : InkWell(onTap: onTap, child: padded);
  }
}

/// 开关行(前导图标 + 标题/副标题 + [Switch])。扁平,放进分组卡里用。
class AppSwitchRow extends StatelessWidget {
  const AppSwitchRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.contentPadding = EdgeInsets.zero,
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) => AppListRow(
        icon: icon,
        leading: leading,
        title: title,
        subtitle: subtitle,
        contentPadding: contentPadding,
        showChevron: false,
        trailing: Switch(value: value, onChanged: onChanged),
      );
}
