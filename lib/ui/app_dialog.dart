import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 统一对话框:主题化 [AlertDialog](surface 底 + 圆角由主题 dialogTheme 给)+ 语义标题。
///
/// 全 App 的确认 / 信息 / 输入弹窗都走它,替掉各处手搓的 AlertDialog。补齐了
/// 弹层家族里唯一的缺口(此前只有 showAppSheet + showAppNotify)。
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required String title,
  Widget? content,
  List<Widget>? actions,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) {
      final p = ctx.palette;
      return AlertDialog(
        title: Text(title,
            style: TextStyle(
                color: p.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800)),
        content: content,
        actions: actions,
      );
    },
  );
}

/// 二次确认弹窗:返回 true=确认。[destructive] 时确认键用危险色(删除类操作)。
Future<bool> showAppConfirm(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool destructive = false,
}) async {
  final ok = await showAppDialog<bool>(
    context,
    title: title,
    content: message == null
        ? null
        : Builder(builder: (ctx) {
            final p = ctx.palette;
            return Text(message,
                style:
                    TextStyle(color: p.textMuted, fontSize: 13, height: 1.5));
          }),
    actions: [
      Builder(
        builder: (ctx) => TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel),
        ),
      ),
      Builder(
        builder: (ctx) {
          final p = ctx.palette;
          return FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: p.statusFail, foregroundColor: Colors.white)
                : null,
            child: Text(confirmLabel),
          );
        },
      ),
    ],
  );
  return ok ?? false;
}
