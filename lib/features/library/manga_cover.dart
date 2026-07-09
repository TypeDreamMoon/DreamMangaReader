import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/models.dart';
import '../common/animations.dart';

/// 从 id 派生一个稳定的封面渐变,用作占位 / 网络封面加载失败时的兜底。
List<Color> coverGradient(String seed) {
  const palette = <List<Color>>[
    [Color(0xFF0E4C5A), Color(0xFF06222B)],
    [Color(0xFFB33A5B), Color(0xFF3A1030)],
    [Color(0xFFC9772B), Color(0xFF5A2410)],
    [Color(0xFF3B3A8F), Color(0xFF171633)],
    [Color(0xFF146B62), Color(0xFF062C28)],
    [Color(0xFF2E7D5B), Color(0xFF0E2A20)],
    [Color(0xFF6E5A7A), Color(0xFF241E2B)],
    [Color(0xFFC43B2A), Color(0xFF431310)],
  ];
  var h = 0;
  for (var i = 0; i < seed.length; i++) {
    h = (h * 31 + seed.codeUnitAt(i)) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

/// 封面卡:网络封面(带 Referer)+ 渐变/网点占位兜底 + 可选书名/角标。
class MangaCover extends StatelessWidget {
  const MangaCover({
    super.key,
    required this.manga,
    this.headers,
    this.onTap,
    this.showTitle = false,
    this.badge = 0,
    this.sourceCount = 1,
    this.updated = false,
    this.radius, // 空=跟随设置里的「封面圆角」
    this.heroTag,
    this.aspect = 3 / 4,
  });

  final Manga manga;
  final Map<String, String>? headers;
  final VoidCallback? onTap;
  final bool showTitle;
  final int badge;

  /// >1 时在右上角显示「N源」角标:多源同名去重后,该书可用的源数量。
  final int sourceCount;

  final bool updated;
  final double? radius;

  /// 封面纵横比(宽:高)。默认 3:4;瀑布流传入按 id 派生的随机比例做高低错落。
  final double aspect;

  /// 非空时启用 Hero 飞入动画(封面在列表→详情间过渡)。同屏内须唯一。
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final r = radius ?? LibraryScope.read(context).coverRadius;
    final grad = coverGradient(manga.id);
    final cover = manga.cover;
    final glyph = manga.title.isEmpty ? '?' : manga.title.characters.first;

    Widget clip = ClipRRect(
          borderRadius: BorderRadius.circular(r),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 占位:渐变 + 网点 + 首字
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: grad,
                  ),
                ),
              ),
              CustomPaint(painter: _HalftonePainter(grad.last)),
              Positioned(
                left: 8,
                top: 6,
                child: Text(
                  glyph,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    shadows: const [Shadow(color: Colors.black45, blurRadius: 4)],
                  ),
                ),
              ),
              // 网络封面(磁盘缓存,带 Referer):加载后覆盖占位;失败/加载中透出占位。
              if (cover != null && cover.isNotEmpty)
                CachedNetworkImage(
                  cacheManager: appImageCache,
                  imageUrl: cover,
                  httpHeaders: headers,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 180),
                  placeholder: (_, __) => const SizedBox.shrink(),
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              if (showTitle)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black54, Colors.transparent],
                      ),
                    ),
                    child: Text(
                      manga.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
              // 多源同名去重角标(右上):该书在几个源里都有。用强调色标出。
              if (sourceCount > 1)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('$sourceCount源',
                        style: TextStyle(
                            color: p.onAccent,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            height: 1.0)),
                  ),
                )
              else if (badge > 0)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: p.accent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text('$badge',
                        style: TextStyle(
                            color: p.onAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.w900)),
                  ),
                )
              else if (updated)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: p.accent,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: p.accent, blurRadius: 8)],
                    ),
                  ),
                ),
            ],
          ),
        );

    if (heroTag != null) clip = Hero(tag: heroTag!, child: clip);
    return Pressable(
      onTap: onTap,
      hoverElevate: true, // 桌面悬停微亮 + 点按回弹
      // 封面(渐变/网点/网络图)排出无障碍树:纯装饰,且批量加载会刷爆 Windows AXTree。
      child: AspectRatio(
          aspectRatio: aspect, child: ExcludeSemantics(child: clip)),
    );
  }
}

/// 列表布局的一行:小封面(带「N源」角标)+ 标题。发现页 / 书架列表布局共用。
Widget coverListTile(
  AppPalette p,
  BuildContext context, {
  required Manga manga,
  Map<String, String>? headers,
  int sourceCount = 1,
  Object? heroTag,
  required VoidCallback onTap,
}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        onTap: onTap,
        hoverElevate: true,
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: MangaCover(
                manga: manga,
                headers: headers,
                sourceCount: sourceCount,
                heroTag: heroTag,
                radius: 8,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(manga.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 13,
                      height: 1.25,
                      fontWeight: FontWeight.w700)),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: p.textMuted),
          ],
        ),
      ),
    );

class _HalftonePainter extends CustomPainter {
  _HalftonePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: 0.18);
    const gap = 7.0;
    for (double y = 0; y < size.height; y += gap) {
      for (double x = 0; x < size.width; x += gap) {
        canvas.drawCircle(Offset(x, y), 1.0, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HalftonePainter old) => old.color != color;
}
