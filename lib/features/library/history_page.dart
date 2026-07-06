import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../detail/detail_page.dart';
import 'manga_cover.dart';

/// 阅读历史:按最近阅读排列,点进详情(从「继续阅读」卡续读),可删除/清空。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  SourceMeta? _metaById(String id) {
    for (final s in registeredSources) {
      if (s.id == id) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = LibraryScope.of(context);
    final history = store.history;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('阅读历史',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          if (history.isNotEmpty)
            IconButton(
              tooltip: '清空',
              onPressed: () => _confirmClear(context, store),
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: history.isEmpty
          ? Center(
              child: Text('还没有阅读记录',
                  style: TextStyle(color: p.textMuted, fontSize: 13)))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              itemCount: history.length,
              itemBuilder: (context, i) => _row(context, p, store, history[i]),
            ),
    );
  }

  Widget _row(
      BuildContext context, AppPalette p, LibraryStore store, ReadState h) {
    final meta = _metaById(h.sourceId);
    final manga = Manga(id: h.mangaId, title: h.title, cover: h.cover);
    final frac =
        h.lastTotal > 0 ? '${h.lastPage + 1}/${h.lastTotal} 页' : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: meta == null
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DetailPage(manga: manga, meta: meta))),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 46,
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
                        '${sourceNameOf(h.sourceId)} · 读到 ${h.lastChapterName}${frac.isNotEmpty ? ' · $frac' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.accentSoft, fontSize: 11.5)),
                  ],
                ),
              ),
              IconButton(
                tooltip: '移除',
                onPressed: () => store.removeHistory(h.sourceId, h.mangaId),
                icon: Icon(Icons.close_rounded, size: 18, color: p.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, LibraryStore store) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空阅读历史'),
        content: const Text('只清历史记录,不影响收藏和下载。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) await store.clearHistory();
  }
}
