import 'dart:io';
import 'dart:ui' show ImageFilter, TileMode;

import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../app/ui_signals.dart';

/// 全局背景层:可选背景图(带模糊)+ 混合色遮罩,垫在所有页面之后。
///
/// 未设背景图时 = 纯主题底色(与之前一致)。设了图时:模糊背景图 + 混合色遮罩
/// (遮罩既统一色调、又压对比度保证文字可读)。在详情页,混合色会往封面主题色混一点。
/// 依赖 scaffoldBackgroundColor 透明(见 app_theme),否则页面底色会盖住背景。
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    final p = context.palette;
    if (lib.bgImage.isEmpty) {
      return ColoredBox(color: p.background, child: child);
    }
    return ValueListenableBuilder<Color?>(
      valueListenable: DetailTint.color,
      builder: (context, detail, _) {
        // 混合色随主题自动:深色系(OLED/Dark)取暗调、Light 取白调 —— 直接用主题底色,
        // 把背景图压成与当前主题一致的明暗,文字在任何背景图上都可读。
        var tint = p.background.withValues(alpha: lib.bgTintAlpha);
        if (detail != null) {
          // 详情页:把混合色往封面主题色混(融合强度设置里可调)。
          // 低强度 → 更接近用户设的底色(默认黑);高强度 → 更接近封面主题色。
          tint = Color.lerp(tint,
              detail.withValues(alpha: lib.bgTintAlpha), lib.detailTintStrength)!;
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: p.background), // 图加载失败/透明区兜底
            // RepaintBoundary:把「底色+模糊背景图」缓存成一层。否则前景内容一滚动、
            // 整个 Stack 重绘就会**每帧重跑一次全屏高斯模糊**(手机 GPU 大开销、掉帧)。
            // 背景是静态的,隔离后只算一次;前景滚动直接复用缓存层。
            Positioned.fill(
              child: RepaintBoundary(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                      sigmaX: lib.bgBlur,
                      sigmaY: lib.bgBlur,
                      tileMode: TileMode.decal),
                  child: Image.file(
                    File(lib.bgImage),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            // 混合色过渡:进出详情/阅读器时封面色 ↔ 设置色平滑淡变。
            Positioned.fill(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: tint),
                duration: LibraryStore.animationsEnabled
                    ? const Duration(milliseconds: 450)
                    : Duration.zero,
                curve: Curves.easeOut,
                builder: (_, c, __) => ColoredBox(color: c ?? tint),
              ),
            ),
            child,
          ],
        );
      },
    );
  }
}
