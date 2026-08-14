import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/page_transitions.dart';

/// 推一个页面,**带连点保护**。
///
/// 推入动画有 240ms,这段时间里新页还没盖满屏幕,底下那页照样吃得到点击 ——
/// 于是对着封面双击(桌面用户的习惯动作)两下各触发一次 onTap,叠出两层一模一样
/// 的页面。
///
/// 判据不是时间窗而是「调用方这一页还在不在最顶上」:不在了,说明刚推上去一个,
/// 这次就是连点的第二下。这样既不用猜延时,也不会误伤「返回上一页后立刻点开
/// 另一个」—— 那时调用方已经重新回到顶部了。
Future<T?> pushPage<T>(BuildContext context, Widget page) =>
    pushRoute<T>(context, appRoute<T>(page));

/// 同上,但用调用方自己给的 route(还在用 MaterialPageRoute 的地方)。
Future<T?> pushRoute<T>(BuildContext context, Route<T> route) {
  final current = ModalRoute.of(context);
  if (current != null && !current.isCurrent) return Future<T?>.value();
  return Navigator.of(context).push<T>(route);
}

/// 统一页面转场:带独立背景的水平推入/退出。
/// 全局「开启动画」关掉时退化为零时长的直接切换。用它替代 MaterialPageRoute。
Route<T> appRoute<T>(Widget page) {
  final animationsEnabled = LibraryStore.animationsEnabled;
  return PageRouteBuilder<T>(
    transitionDuration:
        animationsEnabled ? const Duration(milliseconds: 240) : Duration.zero,
    reverseTransitionDuration:
        animationsEnabled ? const Duration(milliseconds: 220) : Duration.zero,
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, animation, secondaryAnimation, child) =>
        buildDreamPageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    ),
  );
}
