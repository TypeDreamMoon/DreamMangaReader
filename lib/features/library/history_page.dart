import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/anime_library_store.dart';
import '../../app/library_store.dart';
import '../../app/novel_library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../anime/anime_history_resume.dart';
import '../detail/detail_page.dart';
import '../novel/novel_cover.dart';
import '../novel/novel_library_view.dart';
import 'manga_cover.dart';
import 'unified_history.dart';

/// 漫画、小说和番剧共用一条按最近时间排序的历史记录。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  SourceMeta? _metaById(String id) {
    for (final source in registeredSources) {
      if (source.id == id) return source;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final mangaStore = LibraryScope.of(context);
    final novelStore = NovelLibraryScope.of(context);
    final animeStore = AnimeLibraryScope.of(context);
    final items = UnifiedHistoryProjector.build(
      manga: mangaStore.history,
      novel: [
        for (final item in novelStore.history)
          if (novelStore.entryFor(item.key) case final entry?)
            UnifiedNovelHistoryInput(entry: entry, progress: item.value),
      ],
      anime: animeStore.history,
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(
          context.l10n.hist_title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
        ),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              key: const Key('history-clear'),
              tooltip: context.l10n.disc_clear,
              onPressed: () => _confirmClear(
                context,
                mangaStore,
                novelStore,
                animeStore,
              ),
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: items.isEmpty
          ? EmptyState(title: context.l10n.hist_emptyTitle)
          : AppScrollView.builder(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              itemCount: items.length,
              itemBuilder: (context, index) => _historyRow(
                context,
                palette,
                items[index],
                mangaStore,
                novelStore,
                animeStore,
              ),
            ),
    );
  }

  Widget _historyRow(
    BuildContext context,
    AppPalette palette,
    UnifiedHistoryItem item,
    LibraryStore mangaStore,
    NovelLibraryStore novelStore,
    AnimeLibraryStore animeStore,
  ) {
    return switch (item.kind) {
      UnifiedHistoryKind.manga =>
        _mangaRow(context, palette, mangaStore, item.manga!),
      UnifiedHistoryKind.novel => _novelRow(
          context,
          palette,
          novelStore,
          item.novelEntry!,
          item.novelProgress!,
        ),
      UnifiedHistoryKind.anime =>
        _animeRow(context, palette, animeStore, item.anime!),
    };
  }

  Widget _mangaRow(
    BuildContext context,
    AppPalette palette,
    LibraryStore store,
    ReadState history,
  ) {
    final meta = _metaById(history.sourceId);
    final manga = Manga(
      id: history.mangaId,
      title: history.title,
      cover: history.cover,
    );
    final pages = history.lastTotal > 0
        ? context.l10n.hist_pagesFrac(history.lastPage + 1, history.lastTotal)
        : '';
    final progress = context.l10n.hist_readToLine(
      sourceNameOf(history.sourceId),
      history.lastChapterName,
    );
    return _card(
      cardKey: const Key('history-row-manga'),
      palette: palette,
      title: history.title,
      progress: pages.isEmpty ? progress : '$progress · $pages',
      cover: MangaCover(
        manga: manga,
        headers: meta == null ? const {} : imageHeadersOf(meta),
        radius: 8,
      ),
      onTap: meta == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => DetailPage(manga: manga, meta: meta),
              )),
      removeKey: const Key('history-remove-manga'),
      onRemove: () => store.removeHistory(history.sourceId, history.mangaId),
    );
  }

  Widget _novelRow(
    BuildContext context,
    AppPalette palette,
    NovelLibraryStore store,
    NovelLibraryEntry entry,
    NovelReadingProgress progress,
  ) {
    final novel = Novel(
      id: entry.novelId ?? entry.fingerprint ?? entry.key,
      title: entry.title,
      cover: entry.cover,
      authors: entry.authors,
    );
    return _card(
      cardKey: const Key('history-row-novel'),
      palette: palette,
      title: entry.title,
      progress: entry.available
          ? context.l10n.novel_readTo(progress.locator.chapterId)
          : context.l10n.novel_fileMissing,
      cover: NovelCover(novel: novel, radius: 8),
      onTap: entry.available
          ? () => unawaited(openNovelLibraryEntry(context, entry))
          : null,
      removeKey: const Key('history-remove-novel'),
      onRemove: () => store.removeHistory(entry.key),
    );
  }

  Widget _animeRow(
    BuildContext context,
    AppPalette palette,
    AnimeLibraryStore store,
    AnimeHistoryEntry history,
  ) {
    final meta = _metaById(history.sourceId);
    final anime = Manga(
      id: history.animeId,
      title: history.title,
      cover: history.cover,
    );
    final position = _formatDuration(history.positionSeconds);
    final duration = history.durationSeconds > 0
        ? _formatDuration(history.durationSeconds)
        : '--:--';
    return _card(
      cardKey: const Key('history-row-anime'),
      palette: palette,
      title: history.title,
      progress: context.l10n.animeHistoryProgress(
        history.episodeName,
        position,
        duration,
      ),
      cover: MangaCover(
        manga: anime,
        headers: meta == null ? const {} : imageHeadersOf(meta),
        radius: 8,
      ),
      onTap: () => unawaited(openAnimeHistory(context, history)),
      removeKey: const Key('history-remove-anime'),
      onRemove: () => store.removeHistory(history.sourceId, history.animeId),
    );
  }

  Widget _card({
    required Key cardKey,
    required AppPalette palette,
    required String title,
    required String progress,
    required Widget cover,
    required VoidCallback? onTap,
    required Key removeKey,
    required VoidCallback onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        key: cardKey,
        radius: 12,
        padding: const EdgeInsets.all(10),
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(width: 46, height: 61, child: cover),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    progress,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.accentSoft,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: removeKey,
              tooltip: '移除记录',
              onPressed: onRemove,
              icon: Icon(
                Icons.close_rounded,
                size: 18,
                color: palette.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final tail = '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
    return hours > 0 ? '$hours:$tail' : tail;
  }

  Future<void> _confirmClear(
    BuildContext context,
    LibraryStore mangaStore,
    NovelLibraryStore novelStore,
    AnimeLibraryStore animeStore,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.hist_clearTitle),
        content: Text(context.l10n.hist_clearMsg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.disc_clear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await mangaStore.clearHistory();
    novelStore.clearHistory();
    animeStore.clearHistory();
    await Future.wait([
      novelStore.flushPending(),
      animeStore.flushPending(),
    ]);
  }
}
