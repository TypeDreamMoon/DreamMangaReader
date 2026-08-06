import 'package:dream_manga_reader/core/downloads/content_download_task.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('content identity encoding cannot collide on punctuation', () {
    final left = ContentDownloadTask.manga(
      sourceId: 'a:b',
      contentId: 'c',
      contentTitle: '左',
      chapterId: 'd',
      chapterTitle: '章节',
      now: 1,
    );
    final right = ContentDownloadTask.manga(
      sourceId: 'a',
      contentId: 'b:c',
      contentTitle: '右',
      chapterId: 'd',
      chapterTitle: '章节',
      now: 1,
    );

    expect(left.id, isNot(right.id));
  });

  test('queued content payload contains only stable identifiers', () {
    final task = ContentDownloadTask.novel(
      sourceId: 'source',
      contentId: 'novel',
      contentTitle: '小说',
      chapterId: 'chapter',
      chapterTitle: '第一章',
      now: 100,
    );

    expect(task.state, DownloadTaskState.queued);
    expect(task.payload, {
      'sourceId': 'source',
      'contentId': 'novel',
      'chapterId': 'chapter',
    });
    expect(ContentDownloadRequest.fromTask(task).chapterId, 'chapter');
  });

  test('completed content task preserves local compatibility metadata', () {
    final task = ContentDownloadTask.manga(
      sourceId: 'source',
      contentId: 'manga',
      contentTitle: '漫画',
      chapterId: 'chapter',
      chapterTitle: '第一话',
      now: 200,
      completed: true,
      completedBytes: 12,
      totalBytes: 12,
      localDirectory: r'D:\offline\chapter',
      resourceCount: 12,
    );

    expect(task.state, DownloadTaskState.completed);
    expect(task.completedAt, 200);
    expect(task.payload['localDirectory'], r'D:\offline\chapter');
    expect(task.payload['resourceCount'], 12);
  });
}
