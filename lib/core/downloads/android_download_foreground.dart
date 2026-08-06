import 'dart:io';

import 'package:flutter/services.dart';

import 'download_task.dart';

class ContentDownloadForegroundSnapshot {
  const ContentDownloadForegroundSnapshot({
    required this.taskCount,
    required this.completedBytes,
    required this.totalBytes,
    required this.indeterminate,
    required this.currentTitle,
    required this.currentItemTitle,
  });

  factory ContentDownloadForegroundSnapshot.fromTasks(
    Iterable<DownloadTask> tasks,
  ) {
    final active = tasks
        .where((task) => switch (task.state) {
              DownloadTaskState.resolving ||
              DownloadTaskState.queued ||
              DownloadTaskState.running ||
              DownloadTaskState.verifying =>
                true,
              DownloadTaskState.paused ||
              DownloadTaskState.completed ||
              DownloadTaskState.failed ||
              DownloadTaskState.cancelled =>
                false,
            })
        .toList(growable: false);
    if (active.isEmpty) {
      return const ContentDownloadForegroundSnapshot(
        taskCount: 0,
        completedBytes: 0,
        totalBytes: 0,
        indeterminate: false,
        currentTitle: '',
        currentItemTitle: '',
      );
    }
    final current = active
            .where((task) => task.state == DownloadTaskState.running)
            .firstOrNull ??
        active.first;
    return ContentDownloadForegroundSnapshot(
      taskCount: active.length,
      completedBytes: active.fold(
        0,
        (total, task) => total + task.completedBytes,
      ),
      totalBytes: active.fold(0, (total, task) => total + task.totalBytes),
      indeterminate: active.any((task) => task.totalBytes <= 0),
      currentTitle: current.title,
      currentItemTitle: current.itemTitle,
    );
  }

  final int taskCount;
  final int completedBytes;
  final int totalBytes;
  final bool indeterminate;
  final String currentTitle;
  final String currentItemTitle;

  bool get active => taskCount > 0;

  Map<String, Object> toMap() => {
        'taskCount': taskCount,
        'completedBytes': completedBytes,
        'totalBytes': totalBytes,
        'indeterminate': indeterminate,
        'currentTitle': currentTitle,
        'currentItemTitle': currentItemTitle,
      };

  @override
  bool operator ==(Object other) =>
      other is ContentDownloadForegroundSnapshot &&
      other.taskCount == taskCount &&
      other.completedBytes == completedBytes &&
      other.totalBytes == totalBytes &&
      other.indeterminate == indeterminate &&
      other.currentTitle == currentTitle &&
      other.currentItemTitle == currentItemTitle;

  @override
  int get hashCode => Object.hash(
        taskCount,
        completedBytes,
        totalBytes,
        indeterminate,
        currentTitle,
        currentItemTitle,
      );
}

class AndroidDownloadForegroundBridge {
  AndroidDownloadForegroundBridge({
    this.channel = const MethodChannel('dream_manga_reader/downloads'),
    bool? enabled,
  }) : enabled = enabled ?? Platform.isAndroid;

  final MethodChannel channel;
  final bool enabled;
  Future<void> _tail = Future.value();
  ContentDownloadForegroundSnapshot? _last;
  bool _started = false;

  Future<void> sync(Iterable<DownloadTask> tasks) {
    final snapshot = ContentDownloadForegroundSnapshot.fromTasks(tasks);
    Future<void> operation() => _syncSnapshot(snapshot);
    _tail = _tail.then((_) => operation(), onError: (_) => operation());
    return _tail;
  }

  Future<void> _syncSnapshot(
    ContentDownloadForegroundSnapshot snapshot,
  ) async {
    if (!enabled) return;
    if (!snapshot.active) {
      if (!_started) return;
      await channel.invokeMethod<void>('stop');
      _started = false;
      _last = null;
      return;
    }
    if (_started && snapshot == _last) return;
    await channel.invokeMethod<void>(
      _started ? 'update' : 'start',
      snapshot.toMap(),
    );
    _started = true;
    _last = snapshot;
  }
}
