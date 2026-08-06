import 'dart:convert';

import '../core/downloads/download_coordinator.dart';
import '../core/downloads/download_task.dart';
import 'download_store.dart';
import 'novel_download_store.dart';

final class LegacyDownloadMigrator {
  const LegacyDownloadMigrator._();

  static Future<void> migrate({
    required DownloadCoordinator coordinator,
    required DownloadStore mangaDownloads,
    required NovelDownloadStore novelDownloads,
  }) {
    return coordinator.importCompleted(
      buildTasks(
        manga: mangaDownloads.byManga.values.expand((value) => value),
        novels: novelDownloads.downloads,
      ),
    );
  }

  static List<DownloadTask> buildTasks({
    Iterable<DownloadedChapter> manga = const [],
    Iterable<DownloadedNovelChapter> novels = const [],
  }) {
    return List.unmodifiable([
      for (final chapter in manga) _mangaTask(chapter),
      for (final chapter in novels) _novelTask(chapter),
    ]);
  }

  static DownloadTask _mangaTask(DownloadedChapter chapter) {
    return DownloadTask(
      id: _legacyId(
        DownloadContentKind.manga,
        [chapter.sourceId, chapter.mangaId, chapter.chapterId],
      ),
      kind: DownloadContentKind.manga,
      title: chapter.mangaTitle,
      itemTitle: chapter.chapterName,
      state: DownloadTaskState.completed,
      createdAt: chapter.doneAt,
      updatedAt: chapter.doneAt,
      completedBytes: chapter.pageCount,
      totalBytes: chapter.pageCount,
      priority: 0,
      payload: {
        'sourceId': chapter.sourceId,
        'contentId': chapter.mangaId,
        'chapterId': chapter.chapterId,
        'localDirectory': chapter.dir,
        'resourceCount': chapter.pageCount,
        'legacyStore': 'manga',
      },
      completedAt: chapter.doneAt,
    );
  }

  static DownloadTask _novelTask(DownloadedNovelChapter chapter) {
    return DownloadTask(
      id: _legacyId(
        DownloadContentKind.novel,
        [chapter.sourceId, chapter.novelId, chapter.chapterId],
      ),
      kind: DownloadContentKind.novel,
      title: chapter.novel.title,
      itemTitle: chapter.chapter.title,
      state: DownloadTaskState.completed,
      createdAt: chapter.completedAt,
      updatedAt: chapter.completedAt,
      completedBytes: chapter.byteCount,
      totalBytes: chapter.byteCount,
      priority: 0,
      payload: {
        'sourceId': chapter.sourceId,
        'contentId': chapter.novelId,
        'chapterId': chapter.chapterId,
        'localDirectory': chapter.directory,
        'resourceCount': chapter.resourceCount,
        'legacyStore': 'novel',
      },
      completedAt: chapter.completedAt,
    );
  }

  static String _legacyId(
    DownloadContentKind kind,
    List<String> identity,
  ) {
    final encoded = base64Url.encode(utf8.encode(jsonEncode(identity)));
    return 'legacy:${kind.name}:${encoded.replaceAll('=', '')}';
  }
}
