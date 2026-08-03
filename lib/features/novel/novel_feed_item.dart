import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/novel/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import '../library/masonry_feed.dart';
import 'novel_cover.dart';

class NovelFeedCard extends StatelessWidget {
  const NovelFeedCard({
    super.key,
    required this.novel,
    required this.meta,
    required this.layout,
    required this.sourceCountLabel,
    required this.onTap,
  });

  final Novel novel;
  final SourceMeta meta;
  final FeedLayout layout;
  final String? sourceCountLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final author = novel.authors.join(' / ');
    final cover = Stack(
      fit: StackFit.expand,
      children: [
        NovelCover(
          novel: novel,
          headers: imageHeadersOf(meta),
          compactGeneratedTitle: true,
        ),
        Positioned(
          left: 6,
          right: 6,
          bottom: 6,
          child: Align(
            alignment: Alignment.centerRight,
            child: _SourcePill(sourceCountLabel ?? meta.name),
          ),
        ),
      ],
    );
    final framedCover = AspectRatio(
      aspectRatio: layout == FeedLayout.masonry ? aspectForId(novel.id) : 3 / 4,
      child: cover,
    );

    // 与漫画浏览卡同构:Pressable(按压缩放 + 桌面悬停微抬)而非 InkWell 水波,
    // 标题/作者两行、字号 12 / 10 —— 两档混排时卡片高度和字重要能对齐。
    return Pressable(
      onTap: onTap,
      hoverElevate: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (layout == FeedLayout.grid)
            Expanded(child: framedCover)
          else
            framedCover,
          const SizedBox(height: 6),
          Text(
            novel.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            author.isNotEmpty ? author : ' ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class NovelFeedTile extends StatelessWidget {
  const NovelFeedTile({
    super.key,
    required this.novel,
    required this.meta,
    required this.sourceCountLabel,
    required this.onTap,
  });

  final Novel novel;
  final SourceMeta meta;
  final String? sourceCountLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final author = novel.authors.join(' / ');
    final description = (novel.description ?? '').trim();
    // 版式对齐漫画的 coverListTile:palette 面 + 描边 + context.radius,56 宽封面。
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        onTap: onTap,
        hoverElevate: true,
        child: Container(
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(context.radius),
            border: Border.all(color: p.line),
          ),
          padding: const EdgeInsets.all(9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 56,
                child: NovelCover(
                  novel: novel,
                  headers: imageHeadersOf(meta),
                  compactGeneratedTitle: true,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      novel.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 14,
                        height: 1.25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _SourcePill(sourceCountLabel ?? meta.name),
                        if (author.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.textMuted,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textMuted,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourcePill extends StatelessWidget {
  const _SourcePill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    // 与漫画详情页的来源角标同一配方(AppPill.accent 的淡底 + 淡边 + 微亮字)。
    return AppPill.accent(
      label,
      context.palette.accent,
      radius: 6,
      fontSize: 10,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    );
  }
}
