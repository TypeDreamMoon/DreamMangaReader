import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import 'glass.dart';
import 'tab_entrance.dart';

/// 顶部毛玻璃标题栏:透明 [AppBar] + [GlassSurface] 填充(模糊身后背景图/内容)+ 青碧染色,
/// 底部一道分隔线。入场时随 [TabEntrance] 自上而下落入。
///
/// 用法:`Scaffold(extendBodyBehindAppBar: true, appBar: GlassTitleBar(title: ...))`,
/// 页面 body 记得留出顶部 `MediaQuery.viewPadding.top + kToolbarHeight` 的内边距。
class GlassTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassTitleBar({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.dropIn = true,
    this.blur = 22,
  });

  final Widget title;
  final List<Widget>? actions;
  final Widget? leading;

  /// 入场时是否自上而下落入(需外壳提供 [TabEntrance];无则静止)。
  final bool dropIn;
  final double blur;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 染色:在毛玻璃底色上再糅一丝青碧,让标题栏「带色」而不是一块灰玻璃。
    final tint = Color.alphaBlend(
        p.accent.withValues(alpha: 0.05), GlassSurface.glassTint(p));

    final bar = AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: p.textPrimary,
      titleSpacing: 20,
      leading: leading,
      title: title,
      actions: actions,
      flexibleSpace: GlassSurface(
        blur: blur,
        tint: tint,
        border: Border(bottom: BorderSide(color: p.line)),
        child: const SizedBox.expand(),
      ),
    );

    return dropIn ? EntranceSlide(begin: const Offset(0, -1), child: bar) : bar;
  }
}
