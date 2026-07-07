import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import 'glass.dart';

/// 统一底部弹层外壳:圆角顶 + SafeArea + 内边距 + 标题行(+可选拖拽条/关闭/尾部文字)。
///
/// 各页的「设置面板 / 选择器 / 结果表」都走它,只写 [body] 内容。
/// - [heightFactor] 非空 = 限高(屏高 × factor),[body] 里用 `Flexible` 承载可滚动列表;
///   为空 = 随内容自适应,整体套 [SingleChildScrollView]。
/// - [body] 收到 `StateSetter`,面板内即时改值调它刷新(不必自建 StatefulBuilder)。
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required String title,
  IconData? titleIcon,
  String? trailingText,
  bool showCloseButton = false,
  bool showDragHandle = false,
  double topRadius = 18,
  double? heightFactor,
  bool resizeForKeyboard = false,
  bool glass = false,
  EdgeInsets bodyPadding = const EdgeInsets.fromLTRB(18, 12, 18, 8),
  required Widget Function(BuildContext ctx, StateSetter setSheet) body,
}) {
  final p = context.palette;
  final topR = BorderRadius.vertical(top: Radius.circular(topRadius));
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    // 玻璃态:填充交给 GlassSurface(毛玻璃),弹层本身透明。
    backgroundColor: glass ? Colors.transparent : p.surface,
    shape: RoundedRectangleBorder(borderRadius: topR),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final pp = ctx.palette;
        final header = <Widget>[
          if (titleIcon != null) ...[
            Icon(titleIcon, size: 18, color: pp.accent),
            const SizedBox(width: 8),
          ],
          Text(title,
              style: TextStyle(
                  color: pp.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          if (trailingText != null) ...[
            const Spacer(),
            Text(trailingText,
                style: TextStyle(color: pp.textMuted, fontSize: 12)),
          ],
          if (showCloseButton) ...[
            if (trailingText == null) const Spacer(),
            IconButton(
              onPressed: () => Navigator.of(ctx).pop(),
              icon: const Icon(Icons.close_rounded, size: 20),
              color: pp.textMuted,
            ),
          ],
        ];

        final bounded = heightFactor != null;
        final inner = Padding(
          padding: bodyPadding,
          child: Column(
            // 限高时填满(让 body 里的 Flexible/Expanded 列表撑开);自适应时收拢。
            mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showDragHandle)
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 4, bottom: 10),
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                        color: pp.line,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
              Row(children: header),
              const SizedBox(height: 12),
              bounded
                  ? Expanded(child: body(ctx, setSheet))
                  : body(ctx, setSheet),
            ],
          ),
        );

        Widget sheet = heightFactor != null
            ? ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * heightFactor),
                child: inner)
            : SingleChildScrollView(child: inner);
        sheet = SafeArea(top: false, child: sheet);
        if (resizeForKeyboard) {
          sheet = Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: sheet,
          );
        }
        if (glass) {
          sheet = GlassSurface(
            borderRadius: topR,
            blur: 24,
            border: Border.all(color: pp.line),
            child: sheet,
          );
        }
        return sheet;
      },
    ),
  );
}
