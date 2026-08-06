import 'dart:async';

import 'package:flutter/foundation.dart';

import 'download_policy.dart';
import 'download_task.dart';
import 'download_task_repository.dart';

final class DownloadCoordinator extends ChangeNotifier {
  DownloadCoordinator({
    required this.repository,
    required this.environment,
    required this.settings,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final DownloadTaskRepository repository;
  final Future<DownloadEnvironment> Function() environment;
  final DownloadPolicySettings Function() settings;
  final int Function() _clock;

  Map<String, DownloadTask> _tasks = const {};
  Future<void> _mutationTail = Future.value();
  bool _disposed = false;

  List<DownloadTask> get tasks => List.unmodifiable(_ordered(_tasks.values));

  DownloadTask? task(String id) => _tasks[id];

  Future<void> load() => _serialize(() async {
        final loaded = await repository.load();
        _tasks = Map.unmodifiable({for (final task in loaded) task.id: task});
        notifyListeners();
      });

  Future<void> enqueue(DownloadTask task) => _serialize(() async {
        if (_tasks.containsKey(task.id)) {
          throw StateError('download task already exists: ${task.id}');
        }
        if (task.state != DownloadTaskState.queued &&
            task.state != DownloadTaskState.resolving) {
          throw ArgumentError.value(task.state, 'task.state');
        }
        await _commit({..._tasks, task.id: task});
      });

  Future<void> pause(String id) => _serialize(() async {
        final current = _requiredTask(id);
        if (_isTerminal(current.state)) return;
        await _commit({
          ..._tasks,
          id: current.copyWith(
            state: DownloadTaskState.paused,
            pauseReason: DownloadPauseReason.user,
            updatedAt: _clock(),
          ),
        });
      });

  Future<void> resume(String id) => _serialize(() async {
        final current = _requiredTask(id);
        if (current.state != DownloadTaskState.paused) {
          throw StateError('only paused tasks can resume: $id');
        }
        await _commit({
          ..._tasks,
          id: current.copyWith(
            state: DownloadTaskState.queued,
            clearPauseReason: true,
            updatedAt: _clock(),
          ),
        });
      });

  Future<void> pauseAll() => _serialize(() async {
        final next = <String, DownloadTask>{};
        for (final entry in _tasks.entries) {
          final task = entry.value;
          next[entry.key] = _canPause(task.state)
              ? task.copyWith(
                  state: DownloadTaskState.paused,
                  pauseReason: DownloadPauseReason.user,
                  updatedAt: _clock(),
                )
              : task;
        }
        await _commit(next);
      });

  Future<void> resumeAll() => _serialize(() async {
        final next = <String, DownloadTask>{};
        for (final entry in _tasks.entries) {
          final task = entry.value;
          next[entry.key] = task.state == DownloadTaskState.paused &&
                  task.pauseReason == DownloadPauseReason.user
              ? task.copyWith(
                  state: DownloadTaskState.queued,
                  clearPauseReason: true,
                  updatedAt: _clock(),
                )
              : task;
        }
        await _commit(next);
      });

  Future<void> retry(String id) => _serialize(() async {
        final current = _requiredTask(id);
        if (current.state != DownloadTaskState.failed &&
            current.state != DownloadTaskState.cancelled) {
          throw StateError('only failed or cancelled tasks can retry: $id');
        }
        await _commit({
          ..._tasks,
          id: current.copyWith(
            state: DownloadTaskState.queued,
            clearFailure: true,
            clearPauseReason: true,
            updatedAt: _clock(),
          ),
        });
      });

  Future<void> reorder(String id, int priority) => _serialize(() async {
        final current = _requiredTask(id);
        await _commit({
          ..._tasks,
          id: current.copyWith(priority: priority, updatedAt: _clock()),
        });
      });

  Future<void> remove(String id) => _serialize(() async {
        if (!_tasks.containsKey(id)) return;
        final next = {..._tasks}..remove(id);
        await _commit(next);
      });

  Future<void> _commit(Map<String, DownloadTask> next) async {
    final frozen = Map<String, DownloadTask>.unmodifiable(next);
    await repository.save(_ordered(frozen.values));
    _tasks = frozen;
    notifyListeners();
  }

  DownloadTask _requiredTask(String id) {
    final task = _tasks[id];
    if (task == null) throw StateError('download task not found: $id');
    return task;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      if (_disposed) {
        completer.completeError(StateError('DownloadCoordinator is disposed'));
        return;
      }
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

List<DownloadTask> _ordered(Iterable<DownloadTask> tasks) {
  final ordered = tasks.toList(growable: false)
    ..sort((left, right) {
      final priority = right.priority.compareTo(left.priority);
      if (priority != 0) return priority;
      final created = left.createdAt.compareTo(right.createdAt);
      if (created != 0) return created;
      return left.id.compareTo(right.id);
    });
  return ordered;
}

bool _canPause(DownloadTaskState state) => switch (state) {
      DownloadTaskState.resolving ||
      DownloadTaskState.queued ||
      DownloadTaskState.running ||
      DownloadTaskState.verifying =>
        true,
      _ => false,
    };

bool _isTerminal(DownloadTaskState state) => switch (state) {
      DownloadTaskState.completed ||
      DownloadTaskState.failed ||
      DownloadTaskState.cancelled =>
        true,
      _ => false,
    };
