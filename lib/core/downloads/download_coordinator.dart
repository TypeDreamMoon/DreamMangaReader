import 'dart:async';

import 'package:flutter/foundation.dart';

import 'download_executor.dart';
import 'download_failure.dart';
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
  final Map<DownloadContentKind, DownloadExecutor> _executors = {};
  final Map<String, _ActiveDownload> _active = {};
  final Map<String, int> _generations = {};
  Future<void> _mutationTail = Future.value();
  Completer<void>? _idleCompleter;
  bool _pumpRequested = false;
  bool _pumpRunning = false;
  bool _disposed = false;

  List<DownloadTask> get tasks => List.unmodifiable(_ordered(_tasks.values));

  DownloadTask? task(String id) => _tasks[id];

  Future<void> get idle {
    if (_active.isEmpty && !_pumpRequested && !_pumpRunning) {
      return Future.value();
    }
    return (_idleCompleter ??= Completer<void>()).future;
  }

  Future<void> load() async {
    await _serialize(() async {
      final loaded = await repository.load();
      var recovered = false;
      final tasks = <String, DownloadTask>{};
      for (final task in loaded) {
        if (_isTransient(task.state)) {
          recovered = true;
          tasks[task.id] = task.copyWith(
            state: DownloadTaskState.queued,
            clearPauseReason: true,
            updatedAt: _clock(),
          );
        } else {
          tasks[task.id] = task;
        }
      }
      if (recovered) await repository.save(_ordered(tasks.values));
      _tasks = Map.unmodifiable(tasks);
      notifyListeners();
    });
    _requestPump();
  }

  Future<void> enqueue(DownloadTask task) async {
    await _serialize(() async {
      if (_tasks.containsKey(task.id)) {
        throw StateError('download task already exists: ${task.id}');
      }
      if (task.state != DownloadTaskState.queued &&
          task.state != DownloadTaskState.resolving) {
        throw ArgumentError.value(task.state, 'task.state');
      }
      await _commit({..._tasks, task.id: task});
    });
    _requestPump();
  }

  Future<void> pause(String id) async {
    _active[id]?.cancellation.cancel();
    await _serialize(() async {
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
  }

  Future<void> resume(String id) async {
    await _serialize(() async {
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
    _requestPump();
  }

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

  Future<void> resumeAll() async {
    await _serialize(() async {
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
    _requestPump();
  }

  Future<void> retry(String id) async {
    _generations[id] = (_generations[id] ?? 0) + 1;
    await _serialize(() async {
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
    _requestPump();
  }

  Future<void> reorder(String id, int priority) => _serialize(() async {
        final current = _requiredTask(id);
        await _commit({
          ..._tasks,
          id: current.copyWith(priority: priority, updatedAt: _clock()),
        });
      });

  Future<void> remove(String id) async {
    _active[id]?.cancellation.cancel();
    _generations[id] = (_generations[id] ?? 0) + 1;
    await _serialize(() async {
      if (!_tasks.containsKey(id)) return;
      final next = {..._tasks}..remove(id);
      await _commit(next);
    });
  }

  void registerExecutor(DownloadExecutor executor) {
    if (_executors.containsKey(executor.kind)) {
      throw StateError('executor already registered: ${executor.kind.name}');
    }
    _executors[executor.kind] = executor;
    _requestPump();
  }

  Future<void> reevaluate() async {
    await _applyPolicy();
    _requestPump();
  }

  Future<void> _applyPolicy() async {
    final decision = evaluateDownloadPolicy(settings(), await environment());
    await _serialize(() async {
      var changed = false;
      final next = <String, DownloadTask>{};
      for (final entry in _tasks.entries) {
        final task = entry.value;
        if (!decision.allowed && task.state == DownloadTaskState.queued) {
          changed = true;
          next[entry.key] = task.copyWith(
            state: DownloadTaskState.paused,
            pauseReason: decision.pauseReason,
            updatedAt: _clock(),
          );
        } else if (decision.allowed &&
            task.state == DownloadTaskState.paused &&
            task.pauseReason != DownloadPauseReason.user) {
          changed = true;
          next[entry.key] = task.copyWith(
            state: DownloadTaskState.queued,
            clearPauseReason: true,
            updatedAt: _clock(),
          );
        } else {
          next[entry.key] = task;
        }
      }
      if (changed) await _commit(next);
    });
  }

  void _requestPump() {
    if (_disposed || _pumpRequested || _executors.isEmpty) return;
    _pumpRequested = true;
    _idleCompleter ??= Completer<void>();
    scheduleMicrotask(() {
      _pumpRequested = false;
      unawaited(_pump());
    });
  }

  Future<void> _pump() async {
    if (_disposed || _pumpRunning) return;
    _pumpRunning = true;
    try {
      await _applyPolicy();
      while (!_disposed) {
        final slots = settings().maxConcurrentWorks - _active.length;
        if (slots <= 0) break;
        final candidates = tasks
            .where(
              (task) =>
                  task.state == DownloadTaskState.queued &&
                  !_active.containsKey(task.id) &&
                  _executors.containsKey(task.kind),
            )
            .take(slots)
            .toList(growable: false);
        if (candidates.isEmpty) break;
        for (final task in candidates) {
          await _start(task);
        }
      }
    } finally {
      _pumpRunning = false;
      _completeIdleIfSettled();
    }
  }

  Future<void> _start(DownloadTask candidate) async {
    final executor = _executors[candidate.kind];
    if (executor == null || _active.containsKey(candidate.id)) return;
    final generation = _generations[candidate.id] ?? 0;
    final active = _ActiveDownload(
      generation: generation,
      cancellation: DownloadCancellation(),
    );
    _active[candidate.id] = active;
    try {
      await _serialize(() async {
        final current = _tasks[candidate.id];
        if (current == null || current.state != DownloadTaskState.queued) {
          throw const DownloadCancelledException();
        }
        await _commit({
          ..._tasks,
          candidate.id: current.copyWith(
            state: DownloadTaskState.running,
            clearPauseReason: true,
            clearFailure: true,
            updatedAt: _clock(),
          ),
        });
      });
    } on DownloadCancelledException {
      _active.remove(candidate.id);
      return;
    }
    unawaited(_execute(executor, candidate.id, active));
  }

  Future<void> _execute(
    DownloadExecutor executor,
    String id,
    _ActiveDownload active,
  ) async {
    try {
      final current = _tasks[id];
      if (current == null) return;
      final context = DownloadExecutionContext(
        cancellation: active.cancellation,
        reportProgress: (completedBytes, totalBytes) =>
            _updateProgress(id, active.generation, completedBytes, totalBytes),
        checkpoint: () => _checkpoint(id, active.generation),
      );
      await executor.execute(context, current);
      await _setVerifying(id, active.generation);
      await _setCompleted(id, active.generation);
    } on DownloadCancelledException {
      await _setCancelledIfRunning(id, active.generation);
    } on Object catch (error) {
      await _setFailed(id, active.generation, error);
    } finally {
      if (_active[id] == active) _active.remove(id);
      _requestPump();
      _completeIdleIfSettled();
    }
  }

  Future<void> _updateProgress(
    String id,
    int generation,
    int completedBytes,
    int totalBytes,
  ) {
    return _serialize(() async {
      final current = _currentExecutionTask(id, generation);
      await _commit({
        ..._tasks,
        id: current.copyWith(
          completedBytes: completedBytes,
          totalBytes: totalBytes,
          updatedAt: _clock(),
        ),
      });
    });
  }

  Future<void> _checkpoint(String id, int generation) {
    return _serialize(() async {
      _currentExecutionTask(id, generation);
      await repository.save(tasks);
    });
  }

  Future<void> _setVerifying(String id, int generation) {
    return _serialize(() async {
      final current = _currentExecutionTask(id, generation);
      await _commit({
        ..._tasks,
        id: current.copyWith(
          state: DownloadTaskState.verifying,
          updatedAt: _clock(),
        ),
      });
    });
  }

  Future<void> _setCompleted(String id, int generation) {
    return _serialize(() async {
      final current = _currentExecutionTask(
        id,
        generation,
        expectedState: DownloadTaskState.verifying,
      );
      await _commit({
        ..._tasks,
        id: current.copyWith(
          state: DownloadTaskState.completed,
          completedBytes: current.totalBytes,
          completedAt: _clock(),
          clearPauseReason: true,
          clearFailure: true,
          updatedAt: _clock(),
        ),
      });
    });
  }

  Future<void> _setCancelledIfRunning(String id, int generation) async {
    try {
      await _serialize(() async {
        final current = _currentExecutionTask(id, generation);
        await _commit({
          ..._tasks,
          id: current.copyWith(
            state: DownloadTaskState.cancelled,
            failure: DownloadFailure.fromMessage(
              DownloadFailureCode.cancelled,
              'cancelled',
            ),
            updatedAt: _clock(),
          ),
        });
      });
    } on DownloadCancelledException {
      // A user pause or removal already committed the intended state.
    }
  }

  Future<void> _setFailed(String id, int generation, Object error) async {
    try {
      await _serialize(() async {
        final current = _currentExecutionTask(id, generation);
        await _commit({
          ..._tasks,
          id: current.copyWith(
            state: DownloadTaskState.failed,
            failure: DownloadFailure.fromMessage(
              DownloadFailureCode.unknown,
              error.toString(),
            ),
            updatedAt: _clock(),
          ),
        });
      });
    } on DownloadCancelledException {
      // A newer task generation owns this identifier.
    }
  }

  DownloadTask _currentExecutionTask(
    String id,
    int generation, {
    DownloadTaskState expectedState = DownloadTaskState.running,
  }) {
    final active = _active[id];
    final current = _tasks[id];
    if (active == null ||
        active.generation != generation ||
        (_generations[id] ?? 0) != generation ||
        current == null ||
        current.state != expectedState) {
      throw const DownloadCancelledException();
    }
    return current;
  }

  void _completeIdleIfSettled() {
    if (_active.isNotEmpty || _pumpRequested || _pumpRunning) return;
    final completer = _idleCompleter;
    _idleCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

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
    for (final active in _active.values) {
      active.cancellation.cancel();
    }
    _active.clear();
    _completeIdleIfSettled();
    super.dispose();
  }
}

final class _ActiveDownload {
  const _ActiveDownload({
    required this.generation,
    required this.cancellation,
  });

  final int generation;
  final DownloadCancellation cancellation;
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

bool _isTransient(DownloadTaskState state) => switch (state) {
      DownloadTaskState.resolving ||
      DownloadTaskState.running ||
      DownloadTaskState.verifying =>
        true,
      _ => false,
    };
