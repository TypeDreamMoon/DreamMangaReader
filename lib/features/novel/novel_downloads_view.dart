import 'package:flutter/material.dart';

import '../../app/novel_download_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/novel/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import 'novel_cover.dart';
import 'novel_detail_page.dart';
import 'novel_reader_page.dart';

class NovelDownloadsView extends StatelessWidget {
  const NovelDownloadsView({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final store = NovelDownloadScope.of(context);
    final groups = _groups(store);
    if (groups.isEmpty) {
      return EmptyState(
        icon: Icons.menu_book_rounded,
        iconSize: 48,
        title: '暂无小说离线章节',
        titleSize: 16,
        dense: true,
        message: store.activeCount > 0
            ? '正在下载 ${store.activeCount} 个章节'
            : '在小说详情页下载章节后会显示在这里',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (store.activeCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: palette.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '正在下载 ${store.activeCount} 个章节',
                  style: TextStyle(color: palette.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        for (final group in groups) _groupTile(context, palette, store, group),
      ],
    );
  }

  Widget _groupTile(
    BuildContext context,
    AppPalette palette,
    NovelDownloadStore store,
    _NovelDownloadGroup group,
  ) {
    final chapterCount = group.completed.length;
    final bytes = group.completed.fold<int>(
      0,
      (total, chapter) => total + chapter.byteCount,
    );
    final failureCount = group.failures.length;
    final activeCount = group.activities.length;
    final parts = <String>[
      '$chapterCount 章',
      _formatBytes(bytes),
      if (activeCount > 0) '$activeCount 个下载中',
      if (failureCount > 0) '$failureCount 项失败',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        radius: 8,
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openGroup(context, store, group),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                SizedBox(
                  width: 52,
                  child: NovelCover(
                    novel: group.novel,
                    headers: imageHeadersOf(group.source),
                    radius: 6,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.novel.title,
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
                        '${group.source.name} · ${parts.join(' · ')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: palette.textMuted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                if (failureCount > 0)
                  TextButton.icon(
                    onPressed: () {
                      for (final failure in group.failures) {
                        store.retry(
                          failure.source.id,
                          failure.novel.id,
                          failure.chapter.id,
                        );
                      }
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重试'),
                  ),
                IconButton(
                  tooltip: '删除小说离线章节',
                  onPressed: () => _confirmDelete(context, store, group),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    color: palette.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openGroup(
    BuildContext context,
    NovelDownloadStore store,
    _NovelDownloadGroup group,
  ) async {
    SourceMeta? current;
    for (final source in registeredSources) {
      if (source.id == group.source.id && source.isNovel) {
        current = source;
        break;
      }
    }
    if (current != null) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => NovelDetailPage(meta: current!, novel: group.novel),
      ));
      return;
    }
    if (group.completed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('原小说源已不可用，且没有完成的离线章节')),
      );
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _OfflineNovelPage(store: store, group: group),
    ));
  }

  Future<void> _confirmDelete(
    BuildContext context,
    NovelDownloadStore store,
    _NovelDownloadGroup group,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除小说离线内容'),
        content: Text(
          '删除《${group.novel.title}》的 ${group.completed.length} 个离线章节，并取消等待或失败的任务？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await store.deleteNovel(group.source.id, group.novel.id);
    }
  }
}

class _OfflineNovelPage extends StatelessWidget {
  const _OfflineNovelPage({required this.store, required this.group});

  final NovelDownloadStore store;
  final _NovelDownloadGroup group;

  @override
  Widget build(BuildContext context) {
    final records = [...group.completed]..sort((a, b) {
        final left = a.chapter.number;
        final right = b.chapter.number;
        if (left != null && right != null) return left.compareTo(right);
        return a.completedAt.compareTo(b.completedAt);
      });
    return Scaffold(
      appBar: AppBar(title: Text(group.novel.title)),
      body: ListView.builder(
        itemCount: records.length,
        itemBuilder: (context, index) {
          final record = records[index];
          return ListTile(
            leading: const Icon(Icons.offline_pin_rounded),
            title: Text(record.chapter.title),
            subtitle: Text(_formatBytes(record.byteCount)),
            onTap: () => _openReader(context, records, index),
          );
        },
      ),
    );
  }

  Future<void> _openReader(
    BuildContext context,
    List<DownloadedNovelChapter> records,
    int index,
  ) async {
    final chapters =
        records.map((record) => record.chapter).toList(growable: false);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NovelReaderPage(
        novel: group.novel,
        chapters: chapters,
        initialIndex: index,
        libraryKey: NovelIdentity.remote(group.source.id, group.novel.id).key,
        loadDocument: (chapter) async {
          final cached = await store.localDocument(
            group.source.id,
            group.novel.id,
            chapter.id,
          );
          if (cached == null) throw StateError('离线章节已被删除');
          return NovelDocument(
            format: NovelDocumentFormat.html,
            content: cached.html,
            baseUrl: Uri.directory(cached.directory).toString(),
          );
        },
      ),
    ));
  }
}

class _NovelDownloadGroup {
  _NovelDownloadGroup({required this.source, required this.novel});

  final SourceMeta source;
  final Novel novel;
  final List<DownloadedNovelChapter> completed = [];
  final List<NovelDownloadFailure> failures = [];
  final List<NovelDownloadActivity> activities = [];

  int get latestAt {
    var latest = 0;
    for (final item in completed) {
      if (item.completedAt > latest) latest = item.completedAt;
    }
    for (final item in failures) {
      if (item.failedAt > latest) latest = item.failedAt;
    }
    return latest;
  }
}

List<_NovelDownloadGroup> _groups(NovelDownloadStore store) {
  final groups = <String, _NovelDownloadGroup>{};
  String key(String sourceId, String novelId) => '$sourceId\u0000$novelId';

  for (final record in store.downloads) {
    (groups[key(record.source.id, record.novel.id)] ??= _NovelDownloadGroup(
      source: record.source,
      novel: record.novel,
    ))
        .completed
        .add(record);
  }
  for (final failure in store.failures) {
    (groups[key(failure.source.id, failure.novel.id)] ??= _NovelDownloadGroup(
      source: failure.source,
      novel: failure.novel,
    ))
        .failures
        .add(failure);
  }
  for (final activity in store.activities) {
    (groups[key(activity.source.id, activity.novel.id)] ??= _NovelDownloadGroup(
      source: activity.source,
      novel: activity.novel,
    ))
        .activities
        .add(activity);
  }
  final result = groups.values.toList(growable: false)
    ..sort((a, b) => b.latestAt.compareTo(a.latestAt));
  return result;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
