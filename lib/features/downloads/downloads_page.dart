import 'package:flutter/material.dart';

import '../../app/download_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/transitions.dart';
import '../detail/detail_page.dart';
import '../library/manga_cover.dart';

/// 下载:已下载漫画(按本地分组),点进详情离线读,可删除。
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  SourceMeta? _metaById(String id) {
    for (final s in registeredSources) {
      if (s.id == id) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dl = DownloadScope.of(context);
    final groups = dl.byManga;
    final keys = groups.keys.toList()
      ..sort((a, b) =>
          groups[b]!.first.doneAt.compareTo(groups[a]!.first.doneAt));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('下载',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: keys.isEmpty
          ? _empty(p, dl)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              children: [
                if (dl.activeCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: p.accent),
                        ),
                        const SizedBox(width: 8),
                        Text('正在下载 ${dl.activeCount} 话…',
                            style: TextStyle(color: p.textMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                for (final k in keys) _mangaTile(context, p, dl, groups[k]!),
              ],
            ),
    );
  }

  Widget _mangaTile(BuildContext context, AppPalette p, DownloadStore dl,
      List<DownloadedChapter> chapters) {
    final first = chapters.first;
    final meta = _metaById(first.sourceId);
    final manga = Manga(
        id: first.mangaId, title: first.mangaTitle, cover: first.mangaCover);
    final tag = meta == null ? null : 'dl:${meta.id}:${manga.id}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        radius: 12,
        padding: const EdgeInsets.all(10),
        onTap: meta == null
            ? null
            : () => Navigator.of(context).push(appRoute(
                DetailPage(manga: manga, meta: meta, heroTag: tag))),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: MangaCover(
                manga: manga,
                headers: meta != null ? imageHeadersOf(meta) : const {},
                radius: 8,
                heroTag: tag,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(first.mangaTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: p.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5)),
                  const SizedBox(height: 3),
                  Text(
                      '${meta?.name ?? first.sourceId} · ${chapters.length} 话已下载',
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ],
              ),
            ),
            IconButton(
              tooltip: '删除',
              onPressed: () =>
                  _confirmDelete(context, dl, first, chapters.length),
              icon: Icon(Icons.delete_outline_rounded, color: p.textMuted, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, DownloadStore dl,
      DownloadedChapter m, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除下载'),
        content: Text('删除《${m.mangaTitle}》的 $count 话本地缓存?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await dl.deleteManga(m.sourceId, m.mangaId);
  }

  Widget _empty(AppPalette p, DownloadStore dl) => EmptyState(
        icon: Icons.download_rounded,
        iconSize: 48,
        title: '还没有下载',
        titleSize: 16,
        dense: true,
        message: dl.activeCount > 0
            ? '正在下载 ${dl.activeCount} 话…'
            : '在漫画详情页点章节右侧的下载图标',
      );
}
