import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../core/novel/models.dart';
import '../../core/source/source_registry.dart';
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
    final scheme = Theme.of(context).colorScheme;
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

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
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
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          if (author.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 0,
                  ),
            ),
          ],
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
    final scheme = Theme.of(context).colorScheme;
    final author = novel.authors.join(' / ');
    return SizedBox(
      height: 116,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 72,
                height: 96,
                child: NovelCover(
                  novel: novel,
                  headers: imageHeadersOf(meta),
                  compactGeneratedTitle: true,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      novel.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (author.isNotEmpty)
                          Flexible(
                            child: Text(
                              author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    letterSpacing: 0,
                                  ),
                            ),
                          ),
                        if (author.isNotEmpty) const SizedBox(width: 8),
                        Flexible(
                          child: _SourcePill(sourceCountLabel ?? meta.name),
                        ),
                      ],
                    ),
                    if ((novel.description ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        novel.description!.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.35,
                              letterSpacing: 0,
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
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onPrimaryContainer,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}
