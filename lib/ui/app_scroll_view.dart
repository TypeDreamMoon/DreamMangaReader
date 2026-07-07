import 'package:flutter/material.dart';

import 'smooth_scroll.dart';

/// 统一可滚动容器:内置桌面滚轮平滑滚动([SmoothScroll]),各页不用再各写一遍
/// `SmoothScroll(builder: (c) => ListView(controller: c, ...))`。
///
/// - `AppScrollView(children: [...])` —— 直接给孩子列表(等价 ListView)。
/// - `AppScrollView.builder(itemCount, itemBuilder)` —— 懒构建(等价 ListView.builder)。
/// - `AppScrollView.custom(builder)` —— 自定义可滚组件(如 MasonryGridView),
///   把传入的 controller 设到它的 `controller:` 上即可继续享受平滑滚动。
class AppScrollView extends StatelessWidget {
  const AppScrollView({
    super.key,
    required List<Widget> this.children,
    this.padding,
    this.physics,
  })  : itemCount = null,
        itemBuilder = null,
        custom = null;

  const AppScrollView.builder({
    super.key,
    required int this.itemCount,
    required Widget Function(BuildContext, int) this.itemBuilder,
    this.padding,
    this.physics,
  })  : children = null,
        custom = null;

  const AppScrollView.custom({
    super.key,
    required Widget Function(ScrollController controller) this.custom,
  })  : children = null,
        itemCount = null,
        itemBuilder = null,
        padding = null,
        physics = null;

  final List<Widget>? children;
  final int? itemCount;
  final Widget Function(BuildContext, int)? itemBuilder;
  final Widget Function(ScrollController controller)? custom;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return SmoothScroll(
      builder: (c) {
        if (custom != null) return custom!(c);
        if (itemBuilder != null) {
          return ListView.builder(
            controller: c,
            padding: padding,
            physics: physics,
            itemCount: itemCount,
            itemBuilder: itemBuilder!,
          );
        }
        return ListView(
          controller: c,
          padding: padding,
          physics: physics,
          children: children!,
        );
      },
    );
  }
}
