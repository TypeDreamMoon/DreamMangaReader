import '../core/downloads/content_download_task.dart';
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
    return ContentDownloadTask.manga(
      sourceId: chapter.sourceId,
      contentId: chapter.mangaId,
      contentTitle: chapter.mangaTitle,
      chapterId: chapter.chapterId,
      chapterTitle: chapter.chapterName,
      now: chapter.doneAt,
      completed: true,
      completedBytes: chapter.pageCount,
      totalBytes: chapter.pageCount,
      localDirectory: chapter.dir,
      resourceCount: chapter.pageCount,
    );
  }

  static DownloadTask _novelTask(DownloadedNovelChapter chapter) {
    return ContentDownloadTask.novel(
      sourceId: chapter.sourceId,
      contentId: chapter.novelId,
      contentTitle: chapter.novel.title,
      chapterId: chapter.chapterId,
      chapterTitle: chapter.chapter.title,
      now: chapter.completedAt,
      completed: true,
      completedBytes: chapter.byteCount,
      totalBytes: chapter.byteCount,
      localDirectory: chapter.directory,
      resourceCount: chapter.resourceCount,
    );
  }
}
