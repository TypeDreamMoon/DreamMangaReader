import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import 'app_list_row.dart';

/// 外链条目:前导图标 + 标题 + 链接地址(副标题)+ 尾部「新窗打开」标,点击回调打开链接。
///
/// 语义化封装 [AppListRow.card] —— 全 App「跳到外部网址」的独立条目统一用这个,
/// 配色/圆角/描边都走设计系统([AppCard] + [AppListRow]),不手搓样式。
class AppLinkRow extends StatelessWidget {
  const AppLinkRow({
    super.key,
    required this.icon,
    required this.title,
    required this.url,
    required this.onTap,
  });

  final IconData icon;
  final String title;

  /// 副标题展示的链接地址(可传去掉 `https://` 前缀的简短形式)。
  final String url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppListRow.card(
      icon: icon,
      title: title,
      subtitle: url,
      subtitleMaxLines: 1,
      trailing: Icon(Icons.open_in_new_rounded, size: 18, color: p.textMuted),
      onTap: onTap,
    );
  }
}
