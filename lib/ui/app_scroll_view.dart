import 'package:flutter/material.dart';

import 'smooth_scroll.dart';

/// 统一可滚动列表容器 = `ListView` + 桌面滚轮**平滑滚动**([SmoothScroll])。
/// 全项目的 ListView 都用它,平滑滚动的接管逻辑只在一处维护。
///
/// 构造器对应 ListView 家族:
/// - `AppScrollView(children: [...])`            —— 等价 `ListView(children:)`
/// - `AppScrollView.builder(itemCount, itemBuilder)`      —— 等价 `ListView.builder`
/// - `AppScrollView.separated(itemCount, itemBuilder, separatorBuilder)` —— 等价 `ListView.separated`
/// - `AppScrollView.custom(custom)`              —— 自定义可滚组件(把传入 controller 设上去)
///
/// **平滑滚动只在「纵向 + 自身可滚(非 shrinkWrap、非 Never 物理)」时接管**;
/// 横向列表、嵌在别的滚动体里的 shrinkWrap 列表退回普通 ListView(平滑滚动对它们无意义)。
/// 传了 [controller](页面自带无限滚动/位置监听)时,平滑滚动会复用它、不另建。
class AppScrollView extends StatelessWidget {
  const AppScrollView({
    super.key,
    required List<Widget> this.children,
    this.padding,
    this.physics,
    this.controller,
    this.shrinkWrap = false,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.primary,
    this.clipBehavior = Clip.hardEdge,
  })  : itemCount = null,
        itemBuilder = null,
        separatorBuilder = null,
        custom = null;

  const AppScrollView.builder({
    super.key,
    required int this.itemCount,
    required IndexedWidgetBuilder this.itemBuilder,
    this.padding,
    this.physics,
    this.controller,
    this.shrinkWrap = false,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.primary,
    this.clipBehavior = Clip.hardEdge,
  })  : children = null,
        separatorBuilder = null,
        custom = null;

  const AppScrollView.separated({
    super.key,
    required int this.itemCount,
    required IndexedWidgetBuilder this.itemBuilder,
    required IndexedWidgetBuilder this.separatorBuilder,
    this.padding,
    this.physics,
    this.controller,
    this.shrinkWrap = false,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.primary,
    this.clipBehavior = Clip.hardEdge,
  })  : children = null,
        custom = null;

  const AppScrollView.custom({
    super.key,
    required Widget Function(ScrollController controller) this.custom,
    this.controller,
  })  : children = null,
        itemCount = null,
        itemBuilder = null,
        separatorBuilder = null,
        padding = null,
        physics = null,
        shrinkWrap = false,
        scrollDirection = Axis.vertical,
        reverse = false,
        primary = null,
        clipBehavior = Clip.hardEdge;

  final List<Widget>? children;
  final int? itemCount;
  final IndexedWidgetBuilder? itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;
  final Widget Function(ScrollController controller)? custom;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;
  final ScrollController? controller;
  final bool shrinkWrap;
  final Axis scrollDirection;
  final bool reverse;
  final bool? primary;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    // 平滑滚动只对「纵向 + 自身可滚」有意义。custom 自定义组件也享受。
    final smooth = custom != null ||
        (scrollDirection == Axis.vertical &&
            !shrinkWrap &&
            physics is! NeverScrollableScrollPhysics);
    if (!smooth) return _list(controller);
    return SmoothScroll(
      controller: controller,
      builder: (c) => custom != null ? custom!(c) : _list(c),
    );
  }

  Widget _list(ScrollController? c) {
    // 有 controller 时不能再声明 primary(ScrollView 断言互斥)。
    final prim = c != null ? null : primary;
    if (separatorBuilder != null) {
      return ListView.separated(
        controller: c,
        padding: padding,
        physics: physics,
        shrinkWrap: shrinkWrap,
        scrollDirection: scrollDirection,
        reverse: reverse,
        primary: prim,
        clipBehavior: clipBehavior,
        itemCount: itemCount!,
        itemBuilder: itemBuilder!,
        separatorBuilder: separatorBuilder!,
      );
    }
    if (itemBuilder != null) {
      return ListView.builder(
        controller: c,
        padding: padding,
        physics: physics,
        shrinkWrap: shrinkWrap,
        scrollDirection: scrollDirection,
        reverse: reverse,
        primary: prim,
        clipBehavior: clipBehavior,
        itemCount: itemCount,
        itemBuilder: itemBuilder!,
      );
    }
    return ListView(
      controller: c,
      padding: padding,
      physics: physics,
      shrinkWrap: shrinkWrap,
      scrollDirection: scrollDirection,
      reverse: reverse,
      primary: prim,
      clipBehavior: clipBehavior,
      children: children!,
    );
  }
}
