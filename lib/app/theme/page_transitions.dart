import 'package:flutter/material.dart';

import '../../ui/app_background.dart';
import '../library_store.dart';

Widget buildDreamPageTransition({
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
}) {
  final surface = AppBackground(child: child);
  if (!LibraryStore.animationsEnabled) return surface;

  final incoming = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  final outgoing = CurvedAnimation(
    parent: secondaryAnimation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return SlideTransition(
    position: Tween(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(incoming),
    child: SlideTransition(
      position: Tween(
        begin: Offset.zero,
        end: const Offset(-0.08, 0),
      ).animate(outgoing),
      child: surface,
    ),
  );
}

class DreamPageTransitionsBuilder extends PageTransitionsBuilder {
  const DreamPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.isFirst) return child;
    return buildDreamPageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}
