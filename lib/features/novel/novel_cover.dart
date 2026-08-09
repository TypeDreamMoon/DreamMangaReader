import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/novel/models.dart';
import '../common/source_image.dart';

class NovelCover extends StatelessWidget {
  const NovelCover({
    super.key,
    required this.novel,
    this.headers = const {},
    this.localCoverPath,
    this.radius = 8,
    this.compactGeneratedTitle = false,
    this.heroTag,
    this.aspect = 3 / 4,
  });

  final Novel novel;
  final Map<String, String> headers;
  final String? localCoverPath;
  final double radius;
  final bool compactGeneratedTitle;

  /// 封面纵横比(宽:高)。默认 3:4;书架瀑布流传入按 id 派生的比例做高低错落。
  final double aspect;

  /// 非空时启用 Hero 飞入动画(封面在列表→详情间过渡)。同屏内须唯一。
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final colors = _coverColors(novel.title);
    final localPath = localCoverPath;
    final cover = novel.cover ?? '';
    final remote = Uri.tryParse(cover);
    Widget image;
    if (localPath != null && File(localPath).existsSync()) {
      image = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _GeneratedNovelCover(
          title: _generatedLabel,
          colors: colors,
        ),
      );
    } else if (cover.startsWith('data:image/') ||
        (remote != null &&
            (remote.scheme == 'http' || remote.scheme == 'https') &&
            remote.host.isNotEmpty)) {
      final fallback = _GeneratedNovelCover(
        title: _generatedLabel,
        colors: colors,
      );
      image = SourceImage(
        source: cover,
        headers: headers,
        fit: BoxFit.cover,
        fallback: fallback,
      );
    } else {
      image = _GeneratedNovelCover(title: _generatedLabel, colors: colors);
    }

    Widget clip = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(color: colors.background, child: image),
    );
    if (heroTag != null) clip = Hero(tag: heroTag!, child: clip);
    // 封面纯装饰,排出无障碍树(与漫画封面一致:批量加载会刷爆 Windows AXTree)。
    return AspectRatio(
      aspectRatio: aspect,
      child: ExcludeSemantics(child: clip),
    );
  }

  String get _generatedLabel {
    final title = novel.title.trim();
    if (!compactGeneratedTitle || title.isEmpty) return title;
    return title.characters.first;
  }
}

class _GeneratedNovelCover extends StatelessWidget {
  const _GeneratedNovelCover({required this.title, required this.colors});

  final String title;
  final ({Color background, Color accent, Color foreground}) colors;

  @override
  Widget build(BuildContext context) {
    final label = title.trim().isEmpty ? '?' : title.trim();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 96;
        final size = (width * .16).clamp(14.0, 24.0);
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: colors.background),
            Align(
              alignment: Alignment.topCenter,
              child: FractionallySizedBox(
                heightFactor: .07,
                widthFactor: 1,
                child: ColoredBox(color: colors.accent),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 18, 12, 16),
              child: Center(
                child: Text(
                  label,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.foreground,
                    fontSize: size,
                    height: 1.35,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 生成式封面(无网络封面时)的配色:按书名散列取一套,同一本书每次一致。
/// 详情页拿它当「无封面时的主题色」种子 —— 与漫画的 `coverGradient` 同性质。
({Color background, Color accent, Color foreground}) novelCoverColors(
        String seed) =>
    _coverColors(seed);

({Color background, Color accent, Color foreground}) _coverColors(String seed) {
  const palettes = [
    (Color(0xfff1f3f0), Color(0xff315f4c), Color(0xff18352a)),
    (Color(0xfff3eee9), Color(0xff9a3d4d), Color(0xff46242a)),
    (Color(0xffeceef3), Color(0xff365f87), Color(0xff20344d)),
    (Color(0xfff2efe4), Color(0xff7a6134), Color(0xff3f3520)),
    (Color(0xffecebea), Color(0xff704c78), Color(0xff3f2d45)),
  ];
  var hash = 0;
  for (final value in seed.codeUnits) {
    hash = (hash * 31 + value) & 0x7fffffff;
  }
  final selected = palettes[hash % palettes.length];
  return (
    background: selected.$1,
    accent: selected.$2,
    foreground: selected.$3,
  );
}
