import 'package:flutter/material.dart';

import '../../app/library_store.dart';

/// 统一页面转场:淡入 + 轻微放大(280ms easeOutCubic)。
/// 全局「开启动画」关掉时退化为零时长的直接切换。用它替代 MaterialPageRoute。
Route<T> appRoute<T>(Widget page) {
  if (!LibraryStore.animationsEnabled) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
  }
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: 0.97, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}
