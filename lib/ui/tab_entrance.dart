import 'package:flutter/widgets.dart';

/// 把「切页入场动画」(0→1)下发给页面,让页面各区域**按方向各自入场**
/// (标题栏自上而下落、内容自下而上升),而不是整页统一平移。
///
/// 外壳(home_shell)在切页时把 `_t` 挂到这里;页面用 [EntranceSlide] 取用。
class TabEntrance extends InheritedWidget {
  const TabEntrance({super.key, required this.animation, required super.child});

  final Animation<double> animation;

  static Animation<double>? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TabEntrance>()
      ?.animation;

  @override
  bool updateShouldNotify(TabEntrance oldWidget) =>
      oldWidget.animation != animation;
}

/// 入场滑动:从 [begin](相对自身尺寸的比例偏移)滑到原位,由 [TabEntrance] 驱动。
///
/// - 顶部标题栏用 `Offset(0, -1)` → 自上而下落入;
/// - 页面内容用 `Offset(0, 0.06)` → 自下而上升起。
///
/// `SlideTransition` 只在**绘制期**平移,不改变布局尺寸,包住 AppBar 也不打乱 Scaffold 排版。
/// 无 [TabEntrance] 祖先(单测 / 非壳内)时原样返回,不加动画。
class EntranceSlide extends StatelessWidget {
  const EntranceSlide({super.key, required this.begin, required this.child});

  final Offset begin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final anim = TabEntrance.of(context);
    if (anim == null) return child;
    return SlideTransition(
      position: anim.drive(Tween(begin: begin, end: Offset.zero)),
      child: child,
    );
  }
}
