import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// 应用 Logo(漫画风「梦」印)。原图黑白 + 白底,放进白色圆角卡里,
/// 深色 / 浅色主题下都干净利落(像贴在页面上的一枚漫画贴纸)。
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 112, this.radius = 0});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: p.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: size * 0.22,
            spreadRadius: 1,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/logo.png',
        fit: BoxFit.cover,
        // 按**实际显示像素**(尺寸×设备像素比)解码,GPU 几乎不再缩放 → 线稿不发毛;
        // 再配 medium 过滤兜住残余缩放。之前按 3x 解码后 GPU 再降 3x 才是锯齿的来源。
        // cacheWidth: (size * MediaQuery.of(context).devicePixelRatio).ceil(),
        filterQuality: FilterQuality.high,
      ),
    );
  }
}
