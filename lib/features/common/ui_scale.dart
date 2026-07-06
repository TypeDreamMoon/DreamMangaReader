import 'package:flutter/material.dart';

/// 桌面「界面缩放」:整体等比缩放(文字 + 图标 + 间距一起,像浏览器缩放),
/// 且内容按**缩放后的逻辑画布**重新布局——不像 `textScaler` 只放大文字、
/// 撑破固定高度的布局导致溢出。
///
/// 做法:把子树布局在 `窗口尺寸 / scale` 的逻辑画布上(并同步缩小 MediaQuery 的
/// size/padding/insets),再用 FittedBox 等比放大 scale 倍填满真实窗口。矢量内容
/// (文字/图标)在最终设备分辨率下重新光栅化,保持清晰。
class UiScale extends StatelessWidget {
  const UiScale({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    if (scale == 1.0 || size.isEmpty) return child;
    final scaled = size / scale;
    final inv = 1 / scale;
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: scaled.width,
        height: scaled.height,
        child: MediaQuery(
          data: mq.copyWith(
            size: scaled,
            padding: mq.padding * inv,
            viewPadding: mq.viewPadding * inv,
            viewInsets: mq.viewInsets * inv,
          ),
          child: child,
        ),
      ),
    );
  }
}
