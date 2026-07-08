import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// 加载 / 请求失败占位:图标 + 标题 +(可复制)详情 +(可选)重试按钮。
///
/// [onDark]=true 用于黑底沉浸场景(阅读器 / 播放器):用固定亮色而非 palette,
/// 否则浅色主题下 palette 文字色叠在黑底上会看不清(此前阅读器就有这个可读性 bug)。
class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    required this.message,
    this.title = '加载失败',
    this.icon = Icons.cloud_off_rounded,
    this.onRetry,
    this.retryLabel = '重试',
    this.onDark = false,
    this.selectableMessage = true,
  });

  final String message;
  final String title;
  final IconData icon;
  final VoidCallback? onRetry;
  final String retryLabel;
  final bool onDark;
  final bool selectableMessage;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final titleColor = onDark ? Colors.white70 : p.textPrimary;
    final msgColor = onDark ? Colors.white54 : p.textMuted;
    final iconColor = onDark ? Colors.white38 : p.textMuted;
    final msgStyle =
        TextStyle(color: msgColor, fontSize: 12.5, height: 1.5);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: iconColor),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: titleColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            selectableMessage
                ? SelectableText(message,
                    textAlign: TextAlign.center, style: msgStyle)
                : Text(message, textAlign: TextAlign.center, style: msgStyle),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(retryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
