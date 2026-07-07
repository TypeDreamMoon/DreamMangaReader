import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import 'app_card.dart';

/// 统一「图标行 / 列表条目」:前导(图标或自定义)+ 标题(+副标题)+ 尾部。
///
/// 内部就是 [ListTile](保留 Material 的垂直居中/最小高度/标题副标题间距等打磨),
/// 只统一 App 的配色、前导宽、标题间隙与右箭头逻辑 —— 不自己重造行布局。
///
/// 两种形态:
/// - 扁平 `AppListRow(...)`:无底色,放进 [AppCard] 分组卡里用。
/// - 自带卡 `AppListRow.card(...)`:自己包一层 [AppCard](独立条目)。
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
    this.cardPadding = const EdgeInsets.symmetric(horizontal: 4),
  })  : _card = true,
        contentPadding = const EdgeInsets.symmetric(horizontal: 4);

  final IconData? icon;
  final Widget? leading;
  final String title;
  final double titleSize;
  final FontWeight titleWeight;
  final String? subtitle;
  final Color? subtitleColor;
  final int subtitleMaxLines;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool? showChevron;
  final EdgeInsetsGeometry contentPadding;

  final bool _card;
  final EdgeInsetsGeometry cardPadding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final showChev = showChevron ?? (onTap != null && trailing == null);
    final tile = ListTile(
      contentPadding: _card ? cardPadding : contentPadding,
      tileColor: Colors.transparent,
      minLeadingWidth: 0,
      horizontalTitleGap: 10,
      leading: leading ??
          (icon != null ? Icon(icon, color: p.accent, size: 18) : null),
      title: Text(title,
          style: TextStyle(
              color: p.textPrimary, fontWeight: titleWeight, fontSize: titleSize)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!,
              maxLines: subtitleMaxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: subtitleColor ?? p.textMuted, fontSize: 12)),
      trailing: trailing ??
          (showChev
              ? Icon(Icons.chevron_right_rounded, color: p.textMuted)
              : null),
      onTap: onTap,
    );
    return _card ? AppCard(padding: EdgeInsets.zero, child: tile) : tile;
  }
}

/// 开关行(前导图标 + 标题/副标题 + [Switch])。内部就是 [SwitchListTile],
/// 保留 Material 打磨;放进分组卡里用。
class AppSwitchRow extends StatelessWidget {
  const AppSwitchRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.contentPadding = const EdgeInsets.fromLTRB(25, 5, 25, 5),
    this.dense = false,
    this.titleSize = 14,
    this.titleWeight = FontWeight.w700,
    this.subtitleSize = 12,
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry contentPadding;
  final bool dense;
  final double titleSize;
  final FontWeight titleWeight;
  final double subtitleSize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // SwitchListTile 不直接吃 minLeadingWidth/horizontalTitleGap,用 ListTileTheme 传。
    return ListTileTheme.merge(
      minLeadingWidth: 0,
      horizontalTitleGap: 10,
      child: SwitchListTile(
        contentPadding: contentPadding,
        dense: dense,
        tileColor: Colors.transparent,
        secondary: leading ??
            (icon != null ? Icon(icon, color: p.accent, size: 18) : null),
        title: Text(title,
            style: TextStyle(
                color: p.textPrimary,
                fontWeight: titleWeight,
                fontSize: titleSize)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!,
                style: TextStyle(color: p.textMuted, fontSize: subtitleSize)),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
