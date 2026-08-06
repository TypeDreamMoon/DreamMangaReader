import 'package:dream_manga_reader/core/downloads/download_task.dart';

DownloadTask taskFixture({
  String id = 'manga:source:book:chapter',
  DownloadContentKind kind = DownloadContentKind.manga,
  DownloadTaskState state = DownloadTaskState.queued,
  int priority = 0,
}) {
  return DownloadTask(
    id: id,
    kind: kind,
    title: '作品',
    itemTitle: '子项',
    state: state,
    createdAt: 100,
    updatedAt: 100,
    completedBytes: 0,
    totalBytes: 100,
    priority: priority,
    payload: const {'sourceId': 'source', 'contentId': 'book'},
    completedAt: state == DownloadTaskState.completed ? 200 : null,
  );
}
