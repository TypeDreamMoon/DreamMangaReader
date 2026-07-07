import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 空态 / 未配置 / 加载失败占位:（可选）图标 + 标题 +（可选)副文案 +（可选)动作。
///
/// `icon` 为空即退化为纯文字态(很多列表空提示就是一行字)。
/// `center` 为 false 时不自带 [Center],便于嵌进 Sliver/自定义容器。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon,
    required this.title,
    this.message,
    this.selectableMessage = false,
    this.action,
    this.iconSize = 44,
    this.padding = const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
    this.dense = false,
    this.center = true,
    this.titleSize = 15,
  });

  final IconData? icon;
  final String title;
  final String? message;
  final bool selectableMessage;
  final Widget? action;
  final double iconSize;
  final EdgeInsetsGeometry padding;
  final bool dense;
  final bool center;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final gap = dense ? 6.0 : 10.0;
    final col = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: iconSize, color: p.textMuted),
          SizedBox(height: dense ? 10 : 14),
        ],
        Text(title,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: p.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: titleSize)),
        if (message != null) ...[
          SizedBox(height: dense ? 4 : 8),
          selectableMessage
              ? SelectableText(message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textMuted, fontSize: 13, height: 1.5))
              : Text(message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textMuted, fontSize: 13, height: 1.5)),
        ],
        if (action != null) ...[SizedBox(height: gap + 4), action!],
      ],
    );
    final body = Padding(padding: padding, child: col);
    return center ? Center(child: body) : body;
  }
}
