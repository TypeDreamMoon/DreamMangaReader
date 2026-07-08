import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import 'app_list_row.dart';

/// 「点选值行」:图标 + 标题(+副标题)+ 右侧当前值 + 下拉箭头,点一下弹自定义选择器。
///
/// 设置页里 字体 等「点开弹选择器」的设置走它,和开关行 / 列表行同一套图标行外观。
/// 复用 [AppListRow] 的外壳,只把尾部换成「值 + 下拉箭头」。
class AppSelectRow extends StatelessWidget {
  const AppSelectRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    this.valueStyle,
    required this.onTap,
    this.valueMaxWidth = 150,
    this.contentPadding = const EdgeInsets.fromLTRB(25, 0, 25, 0),
  });

  final IconData? icon;
  final String title;
  final String? subtitle;

  /// 当前选中值(如字体名);[valueStyle] 可用来用该字体自身渲染。
  final String value;
  final TextStyle? valueStyle;
  final VoidCallback onTap;
  final double valueMaxWidth;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppListRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: 1,
      onTap: onTap,
      contentPadding: contentPadding,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: valueMaxWidth),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: valueStyle ?? TextStyle(color: p.textMuted, fontSize: 13),
            ),
          ),
          Icon(Icons.arrow_drop_down_rounded, color: p.textMuted),
        ],
      ),
    );
  }
}
