import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/color/cover_palette.dart';
import '../../core/net/image_cache.dart';
import '../../ui/ui.dart';
import '../library/manga_cover.dart' show coverGradient;

/// 详情页头图:封面色渐变 + 半透明大图背景 + 底部压暗 + 「封面 / 来源 / 标题 /
/// 作者 / 状态·题材」信息列。
///
/// 三个详情页原本各写一份,连 268 高、0.55 透明度、88 宽封面、渐变 stops
/// 都是同一组数。真正不同的只有:封面组件(漫画/番剧走网络封面,小说可能是生成的)、
/// 背景大图取不取得到、作者行可不可点 —— 都留成参数。
class DetailHero extends StatelessWidget {
  const DetailHero({
    super.key,
    required this.gradientSeed,
    required this.palette,
    required this.accent,
    required this.cover,
    required this.sourceName,
    required this.title,
    required this.statusText,
    required this.genres,
    this.backdropUrl,
    this.backdropHeaders = const {},
    this.authorLine,
  });

  /// 派生兜底渐变的稳定种子(作品 id)。
  final String gradientSeed;

  /// 封面取色结果;null = 用 [gradientSeed] 派生的兜底渐变。
  final CoverPalette? palette;
  final Color accent;

  /// 88 宽的封面组件(漫画/番剧给 [MangaCover],小说给 NovelCover)。
  final Widget cover;

  final String sourceName;
  final String title;
  final String statusText;
  final List<String> genres;

  /// 铺在头图上的大图;null = 只用渐变(小说的生成式封面没有网络图)。
  final String? backdropUrl;
  final Map<String, String> backdropHeaders;

  /// 作者行;null = 不显示。漫画/番剧给可点的版本,小说给纯文本。
  final Widget? authorLine;

  static const double height = 268;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final grad = coverGradient(gradientSeed);
    final gradTop = palette?.primary ?? grad.first;
    final gradBot = palette?.secondary ?? grad.last;
    final backdrop = backdropUrl;
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 450),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [gradTop.withValues(alpha: 0.9), gradBot],
              ),
            ),
          ),
          if (backdrop != null && backdrop.isNotEmpty)
            ExcludeSemantics(
              child: Opacity(
                opacity: 0.55,
                child: CachedNetworkImage(
                  cacheManager: appImageCache,
                  imageUrl: backdrop,
                  httpHeaders: backdropHeaders,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const SizedBox.shrink(),
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          // 底部压暗,让信息列压得住背景图。
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  p.background.withValues(alpha: 0.25),
                  p.background.withValues(alpha: 0.7),
                  p.background,
                ],
                stops: const [0.0, 0.65, 1.0],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(width: 88, child: cover),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 来源角标
                      AppPill(
                        text: sourceName,
                        fill: accent.withValues(alpha: 0.16),
                        textColor: Color.lerp(accent, Colors.white, 0.35),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        radius: 6,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                      if (authorLine != null) ...[
                        const SizedBox(height: 4),
                        authorLine!,
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          AppPill.accent(statusText, accent),
                          for (final genre in genres.take(6))
                            AppPill.outlined(genre, p),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
