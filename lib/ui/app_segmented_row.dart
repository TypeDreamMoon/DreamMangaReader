import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 统一「分段选择行」:前导图标 + 标题(+副标题)在左,[SegmentedButton] 在右 —— 横向排布,
/// 与开关行 [AppSwitchRow]、点选行 [AppSelectRow] 同一副长相(参照「开启动画」开关行)。
///
/// 分段控件比开关宽:当行宽够(桌面/宽窗)时标题左、分段右横排;窄到放不下(手机)时
/// 自动降级成「标题在上、分段整宽在下」,避免溢出。阈值可用 [horizontalMinWidth] 调。
///
/// 自身是「扁平」布局控件(不带底/边框);描边由外层 [AppCard] 提供,与其它设置行统一。
class AppSegmentedRow<T> extends StatelessWidget {
  const AppSegmentedRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.showSelectedIcon = false,
    this.contentPadding = const EdgeInsets.fromLTRB(16, 8, 16, 8),
    this.horizontalMinWidth = 460,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>> onSelectionChanged;
  final bool showSelectedIcon;
  final EdgeInsetsGeometry contentPadding;

  /// 可用宽度 ≥ 此值才横排(标题左 / 分段右);否则分段换行到标题下方整宽铺开。
  final double horizontalMinWidth;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    Widget header() => Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: p.accent),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textMuted, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ],
        );

    Widget control({bool fill = false}) {
      final btn = SegmentedButton<T>(
        segments: segments,
        selected: selected,
        showSelectedIcon: showSelectedIcon,
        onSelectionChanged: onSelectionChanged,
      );
      return fill ? SizedBox(width: double.infinity, child: btn) : btn;
    }

    return Padding(
      padding: contentPadding,
      child: LayoutBuilder(
        builder: (ctx, cons) {
          if (cons.maxWidth >= horizontalMinWidth) {
            // 宽:横排 —— 标题左、分段右(与开关行一致)。
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: header()),
                const SizedBox(width: 14),
                control(),
              ],
            );
          }
          // 窄:标题在上、分段整宽在下。
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header(),
              const SizedBox(height: 10),
              control(fill: true),
            ],
          );
        },
      ),
    );
  }
}
