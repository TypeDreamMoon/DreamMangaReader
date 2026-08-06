import 'package:flutter/material.dart';

import '../../app/anime_download_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import '../common/transitions.dart';
import 'anime_player_page.dart';

class AnimeDownloadsView extends StatelessWidget {
  const AnimeDownloadsView({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AnimeDownloadScope.of(context);
    final groups = <String, List<DownloadedAnimeEpisode>>{};
    for (final episode in store.downloads) {
      (groups['${episode.sourceId}\u0000${episode.animeId}'] ??= [])
          .add(episode);
    }
    final entries = groups.values.toList()
      ..sort((left, right) =>
          right.first.completedAt.compareTo(left.first.completedAt));
    if (entries.isEmpty) {
      return const EmptyState(
        icon: Icons.movie_outlined,
        iconSize: 48,
        title: '暂无已下载番剧',
        titleSize: 16,
        dense: true,
      );
    }
    return AppScrollView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      children: [
        for (final group in entries) ...[
          _AnimeDownloadGroup(episodes: group),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

class _AnimeDownloadGroup extends StatelessWidget {
  const _AnimeDownloadGroup({required this.episodes});

  final List<DownloadedAnimeEpisode> episodes;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ordered = episodes.toList()..sort(_compareEpisodes);
    final first = ordered.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.movie_outlined, color: p.accent, size: 20),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                first.animeTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              '${ordered.length} 集',
              style: TextStyle(color: p.textMuted, fontSize: 11.5),
            ),
          ],
        ),
        const SizedBox(height: 9),
        for (var index = 0; index < ordered.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FadeSlideIn(
              delayMs: 25 * index.clamp(0, 8),
              child: AppCard(
                radius: 8,
                onTap: () => _open(context, ordered, index),
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                child: Row(
                  children: [
                    Icon(Icons.play_circle_outline_rounded,
                        color: p.accentSoft, size: 21),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        ordered[index].episodeTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _sizeLabel(ordered[index].byteCount),
                      style: TextStyle(color: p.textMuted, fontSize: 10.5),
                    ),
                    const SizedBox(width: 5),
                    Icon(Icons.chevron_right_rounded,
                        color: p.textMuted, size: 18),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _open(
    BuildContext context,
    List<DownloadedAnimeEpisode> ordered,
    int index,
  ) {
    final first = ordered.first;
    final meta = registeredSources
            .where((source) => source.id == first.sourceId)
            .firstOrNull ??
        SourceMeta(
          id: first.sourceId,
          name: '离线',
          script: '',
          kind: 'anime',
        );
    Navigator.of(context).push(appRoute(AnimePlayerPage(
      meta: meta,
      animeId: first.animeId,
      animeTitle: first.animeTitle,
      episodes: [
        for (final episode in ordered)
          Chapter(id: episode.episodeId, name: episode.episodeTitle),
      ],
      index: index,
    )));
  }
}

int _compareEpisodes(
  DownloadedAnimeEpisode left,
  DownloadedAnimeEpisode right,
) {
  final leftNumber = _episodeNumber(left.episodeTitle);
  final rightNumber = _episodeNumber(right.episodeTitle);
  if (leftNumber != null && rightNumber != null && leftNumber != rightNumber) {
    return leftNumber.compareTo(rightNumber);
  }
  return left.episodeTitle.compareTo(right.episodeTitle);
}

double? _episodeNumber(String title) =>
    double.tryParse(RegExp(r'\d+(?:\.\d+)?').firstMatch(title)?.group(0) ?? '');

String _sizeLabel(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}
