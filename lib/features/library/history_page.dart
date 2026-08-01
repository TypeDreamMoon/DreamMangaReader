import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/novel_library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../detail/detail_page.dart';
import '../novel/novel_cover.dart';
import '../novel/novel_library_view.dart';
import 'library_kind_switch.dart';
import 'manga_cover.dart';

/// 阅读历史:按最近阅读排列,点进详情(从「继续阅读」卡续读),可删除/清空。
class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    this.showNovelInitially = false,
  });

  final bool showNovelInitially;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late LibraryKind _kind =
      widget.showNovelInitially ? LibraryKind.novel : LibraryKind.manga;

  SourceMeta? _metaById(String id) {
    for (final s in registeredSources) {
      if (s.id == id) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final mangaStore = LibraryScope.of(context);
    final novelStore = NovelLibraryScope.of(context);
    final mangaHistory = mangaStore.history;
    final novelHistory = [
      for (final item in novelStore.history)
        if (novelStore.entryFor(item.key) case final entry?)
          (entry: entry, progress: item.value),
    ];
    final hasHistory = _kind == LibraryKind.manga
        ? mangaHistory.isNotEmpty
        : novelHistory.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(context.l10n.hist_title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          LibraryKindSwitch(
            selected: _kind,
            onSelected: (value) => setState(() => _kind = value),
          ),
          if (hasHistory)
            IconButton(
              tooltip: context.l10n.disc_clear,
              onPressed: () => _confirmClear(
                context,
                mangaStore,
                novelStore,
              ),
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _kind == LibraryKind.manga
          ? mangaHistory.isEmpty
              ? EmptyState(title: context.l10n.hist_emptyTitle)
              : AppScrollView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                  itemCount: mangaHistory.length,
                  itemBuilder: (context, i) =>
                      _row(context, p, mangaStore, mangaHistory[i]),
                )
          : novelHistory.isEmpty
              ? const EmptyState(title: '暂无小说阅读历史')
              : AppScrollView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                  itemCount: novelHistory.length,
                  itemBuilder: (context, i) => _novelRow(
                    context,
                    p,
                    novelStore,
                    novelHistory[i].entry,
                    novelHistory[i].progress,
                  ),
                ),
    );
  }

  Widget _novelRow(
    BuildContext context,
    AppPalette p,
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        radius: 12,
        padding: const EdgeInsets.all(10),
        onTap: entry.available
            ? () => openNovelLibraryEntry(context, entry)
            : null,
        child: Row(
          children: [
            SizedBox(width: 46, child: NovelCover(novel: novel, radius: 8)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.available
                        ? '读到 ${progress.locator.chapterId}'
                        : '文件缺失',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.accentSoft, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: context.l10n.hist_remove,
              onPressed: () => store.removeHistory(entry.key),
              icon: Icon(Icons.close_rounded, size: 18, color: p.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
      BuildContext context, AppPalette p, LibraryStore store, ReadState h) {
    final meta = _metaById(h.sourceId);
    final manga = Manga(id: h.mangaId, title: h.title, cover: h.cover);
    final frac = h.lastTotal > 0
        ? context.l10n.hist_pagesFrac(h.lastPage + 1, h.lastTotal)
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        radius: 12,
        padding: const EdgeInsets.all(10),
        onTap: meta == null
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DetailPage(manga: manga, meta: meta))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
              SizedBox(
                width: 46,
                height: 61, // 显式高度(46×4/3),否则 AspectRatio 撑高整行
                child: MangaCover(
                  manga: manga,
                  headers: meta != null ? imageHeadersOf(meta) : const {},
                  radius: 8,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(h.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: p.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5)),
                    const SizedBox(height: 3),
                    Text(
                        '${context.l10n.hist_readToLine(sourceNameOf(h.sourceId), h.lastChapterName)}${frac.isNotEmpty ? ' · $frac' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.accentSoft, fontSize: 11.5)),
                  ],
                ),
              ),
            IconButton(
              tooltip: context.l10n.hist_remove,
              onPressed: () => store.removeHistory(h.sourceId, h.mangaId),
              icon: Icon(Icons.close_rounded, size: 18, color: p.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    LibraryStore mangaStore,
    NovelLibraryStore novelStore,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.hist_clearTitle),
        content: Text(context.l10n.hist_clearMsg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l10n.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(context.l10n.disc_clear)),
        ],
      ),
    );
    if (ok != true) return;
    if (_kind == LibraryKind.manga) {
      await mangaStore.clearHistory();
    } else {
      novelStore.clearHistory();
    }
  }
}
