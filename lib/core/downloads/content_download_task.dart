import 'dart:convert';

import 'download_task.dart';

final class ContentDownloadTask {
  const ContentDownloadTask._();

  static DownloadTask manga({
    required String sourceId,
    required String contentId,
    required String contentTitle,
    required String chapterId,
    required String chapterTitle,
    required int now,
    int priority = 0,
    bool completed = false,
    int completedBytes = 0,
    int totalBytes = 0,
    String? localDirectory,
    int? resourceCount,
  }) {
    return _chapter(
      kind: DownloadContentKind.manga,
      sourceId: sourceId,
      contentId: contentId,
      contentTitle: contentTitle,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      now: now,
      priority: priority,
      completed: completed,
      completedBytes: completedBytes,
      totalBytes: totalBytes,
      localDirectory: localDirectory,
      resourceCount: resourceCount,
    );
  }

  static DownloadTask novel({
    required String sourceId,
    required String contentId,
    required String contentTitle,
    required String chapterId,
    required String chapterTitle,
    required int now,
    int priority = 0,
    bool completed = false,
    int completedBytes = 0,
    int totalBytes = 0,
    String? localDirectory,
    int? resourceCount,
  }) {
    return _chapter(
      kind: DownloadContentKind.novel,
      sourceId: sourceId,
      contentId: contentId,
      contentTitle: contentTitle,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      now: now,
      priority: priority,
      completed: completed,
      completedBytes: completedBytes,
      totalBytes: totalBytes,
      localDirectory: localDirectory,
      resourceCount: resourceCount,
    );
  }

  static DownloadTask _chapter({
    required DownloadContentKind kind,
    required String sourceId,
    required String contentId,
    required String contentTitle,
    required String chapterId,
    required String chapterTitle,
    required int now,
    required int priority,
    required bool completed,
    required int completedBytes,
    required int totalBytes,
    required String? localDirectory,
    required int? resourceCount,
  }) {
    _requireText(sourceId, 'sourceId');
    _requireText(contentId, 'contentId');
    _requireText(chapterId, 'chapterId');
    final payload = <String, Object?>{
      'sourceId': sourceId,
      'contentId': contentId,
      'chapterId': chapterId,
      if (localDirectory != null) 'localDirectory': localDirectory,
      if (resourceCount != null) 'resourceCount': resourceCount,
    };
    return DownloadTask(
      id: contentDownloadTaskId(kind, sourceId, contentId, chapterId),
      kind: kind,
      title: contentTitle,
      itemTitle: chapterTitle,
      state: completed ? DownloadTaskState.completed : DownloadTaskState.queued,
      createdAt: now,
      updatedAt: now,
      completedBytes: completedBytes,
      totalBytes: totalBytes,
      priority: priority,
      payload: payload,
      completedAt: completed ? now : null,
    );
  }
}

final class ContentDownloadRequest {
  const ContentDownloadRequest({
    required this.sourceId,
    required this.contentId,
    required this.chapterId,
  });

  factory ContentDownloadRequest.fromTask(DownloadTask task) {
    if (task.kind != DownloadContentKind.manga &&
        task.kind != DownloadContentKind.novel) {
      throw FormatException('unsupported content task kind: ${task.kind.name}');
    }
    return ContentDownloadRequest(
      sourceId: _payloadText(task, 'sourceId'),
      contentId: _payloadText(task, 'contentId'),
      chapterId: _payloadText(task, 'chapterId'),
    );
  }

  final String sourceId;
  final String contentId;
  final String chapterId;
}

String contentDownloadTaskId(
  DownloadContentKind kind,
  String sourceId,
  String contentId,
  String chapterId,
) {
  if (kind != DownloadContentKind.manga && kind != DownloadContentKind.novel) {
    throw ArgumentError.value(kind, 'kind');
  }
  final encoded = base64Url.encode(
    utf8.encode(jsonEncode([sourceId, contentId, chapterId])),
  );
  return 'content:${kind.name}:${encoded.replaceAll('=', '')}';
}

String _payloadText(DownloadTask task, String key) {
  final value = task.payload[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw FormatException('invalid content task payload: $key');
}

void _requireText(String value, String name) {
  if (value.trim().isEmpty) throw ArgumentError.value(value, name);
}
