import 'package:flutter/material.dart';

import '../../app/anime_library_store.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../common/transitions.dart';
import 'anime_player_page.dart';

typedef AnimeHistoryPlayerBuilder = Widget Function(
  SourceMeta meta,
  String animeId,
  String title,
  List<Chapter> episodes,
  int index,
  Duration initialPosition,
);

Future<void> openAnimeHistory(
  BuildContext context,
  AnimeHistoryEntry entry, {
  MangaSource Function(SourceMeta meta) sourceBuilder = buildSource,
  List<SourceMeta>? sources,
  AnimeHistoryPlayerBuilder playerBuilder = _buildPlayer,
}) async {
  MangaSource? source;
  try {
    final catalog = sources ?? registeredSources;
    final meta = catalog
        .where(
            (candidate) => candidate.id == entry.sourceId && candidate.isAnime)
        .firstOrNull;
    if (meta == null) throw StateError('番剧源不可用');

    source = sourceBuilder(meta);
    final episodes = await _loadEpisodes(source, entry.animeId);
    if (episodes.isEmpty) throw StateError('没有可播放的分集');
    final matchingIndex =
        episodes.indexWhere((episode) => episode.id == entry.episodeId);
    final index = matchingIndex >= 0
        ? matchingIndex
        : entry.episodeIndex.clamp(0, episodes.length - 1);
    source.dispose();
    source = null;
    if (!context.mounted) return;

    await Navigator.of(context).push(appRoute(playerBuilder(
      meta,
      entry.animeId,
      entry.title,
      episodes,
      index,
      Duration(seconds: entry.positionSeconds),
    )));
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.animeResumeFailed('$error'))),
    );
  } finally {
    source?.dispose();
  }
}

Future<List<Chapter>> _loadEpisodes(
  MangaSource source,
  String animeId,
) async {
  final episodes = <Chapter>[];
  var result = await source.getChapters(animeId);
  episodes.addAll(result.items);
  for (var page = 2; result.hasNext && page <= 100; page++) {
    result = await source.getChapters(animeId, page: page);
    if (result.items.isEmpty) break;
    episodes.addAll(result.items);
  }
  return List.unmodifiable(episodes);
}

Widget _buildPlayer(
  SourceMeta meta,
  String animeId,
  String title,
  List<Chapter> episodes,
  int index,
  Duration initialPosition,
) =>
    AnimePlayerPage(
      meta: meta,
      animeId: animeId,
      animeTitle: title,
      episodes: episodes,
      index: index,
      initialPosition: initialPosition,
    );
