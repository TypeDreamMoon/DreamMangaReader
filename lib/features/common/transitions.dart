import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/page_transitions.dart';

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
