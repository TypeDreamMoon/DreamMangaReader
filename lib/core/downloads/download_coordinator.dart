import 'dart:async';

import 'package:flutter/foundation.dart';

import 'download_executor.dart';
import 'download_failure.dart';
import 'download_failure_classifier.dart';
import 'download_policy.dart';
import 'download_task.dart';
import 'download_task_repository.dart';

final class DownloadCoordinator extends ChangeNotifier {
  DownloadCoordinator({
    required this.repository,
    required this.environment,
    required this.settings,
    int Function()? clock,
    Future<void> Function(Duration)? retryDelay,
    int Function()? progressClock,
  })  : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _retryDelay = retryDelay ?? Future<void>.delayed,
        _progressClock =
            progressClock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 进度落盘的最小间隔。进度本身只改内存里的任务表,写盘按这个节流 ——
  /// 状态迁移([_commit])与 [DownloadExecutionContext.checkpoint] 仍然立即写。
  static const progressPersistInterval = Duration(seconds: 2);

  /// 进度通知监听者的最小间隔:UI 与 Android 前台通知都挂在 notifyListeners 上,
  /// 每收到一个字节就刷一次纯属自找卡顿。
  static const progressNotifyInterval = Duration(milliseconds: 500);

  /// 可重试错误码自动重试的次数上限,超过才真正判定为 failed。
  static const maxAutomaticRetries = 3;

  /// 退避基数:第 n 次重试等 `1s * 4^(n-1)` —— 1s / 4s / 16s。
  static const retryBackoffBase = Duration(seconds: 1);

  final DownloadTaskRepository repository;
  final Future<DownloadEnvironment> Function() environment;
  final DownloadPolicySettings Function() settings;
  final int Function() _clock;
  final Future<void> Function(Duration) _retryDelay;

  /// 墙上时钟(毫秒),只用来做节流。与 [_clock] 分开:后者是任务的逻辑时间戳,
  /// 测试里常做成「每取一次 +1」的计数器,拿它算时间间隔会得到荒唐的结果。
  final int Function() _progressClock;

  Map<String, DownloadTask> _tasks = const {};
  final Map<DownloadContentKind, DownloadExecutor> _executors = {};
  final Map<String, _ActiveDownload> _active = {};
  final Map<String, int> _generations = {};
  final Map<String, int> _retryAttempts = {};
  int _pendingRetries = 0;
  int _lastProgressSaveAt = 0;
  int _lastProgressNotifyAt = 0;
  bool _progressDirty = false;
  Future<void> _mutationTail = Future.value();
  Completer<void>? _idleCompleter;
  bool _pumpRequested = false;
  bool _pumpRunning = false;
  bool _disposed = false;

  List<DownloadTask> get tasks => List.unmodifiable(_ordered(_tasks.values));

  DownloadTask? task(String id) => _tasks[id];

  Future<void> get idle {
    if (_settled) return Future.value();
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

  Future<void> importCompleted(Iterable<DownloadTask> tasks) {
    return _serialize(() async {
      final imports = tasks.toList(growable: false);
      for (final task in imports) {
        if (task.state != DownloadTaskState.completed) {
          throw ArgumentError.value(task.state, 'task.state');
        }
      }

      final next = {..._tasks};
      var changed = false;
      for (final task in imports) {
        final existing = next[task.id];
        if (existing?.state == DownloadTaskState.completed) continue;
        next[task.id] = task;
        changed = true;
      }
      if (changed) await _commit(next);
    });
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
    _retryAttempts.remove(id);
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

  Future<void> pauseAll() {
    // 与 pause 对齐:先取消在途下载,否则任务标成 paused 但执行器还在写盘。
    for (final active in _active.values) {
      active.cancellation.cancel();
    }
    return _serialize(() async {
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
  }

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
    _retryAttempts.remove(id);
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
    _retryAttempts.remove(id);
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
    if (!decision.allowed) {
      // 策略变得不允许时,在途任务也要停:先发取消,执行器抛
      // DownloadCancelledException 退出,已下载的字节数留在任务上供续传。
      for (final entry in _active.entries) {
        if (_tasks[entry.key]?.state != DownloadTaskState.running) continue;
        entry.value.cancellation.cancel();
      }
    }
    await _serialize(() async {
      var changed = false;
      final next = <String, DownloadTask>{};
      for (final entry in _tasks.entries) {
        final task = entry.value;
        if (!decision.allowed && _policyPausable(task.state)) {
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
    return _serializeExecution(() async {
      final current = _currentExecutionTask(id, generation);
      _tasks = Map<String, DownloadTask>.unmodifiable({
        ..._tasks,
        id: current.copyWith(
          completedBytes: completedBytes,
          totalBytes: totalBytes,
          updatedAt: _clock(),
        ),
      });
      _progressDirty = true;
      final now = _progressClock();
      if (now - _lastProgressSaveAt >= progressPersistInterval.inMilliseconds) {
        await _persistTasks(now);
      }
      if (now - _lastProgressNotifyAt >=
          progressNotifyInterval.inMilliseconds) {
        _lastProgressNotifyAt = now;
        notifyListeners();
      }
    });
  }

  /// 执行器显式要求「把目前的进度立刻落盘」(例如刚写完一个大分片,
  /// 此刻崩溃也不想从头再来)。绕过节流写一次,并把攒着的进度刷给 UI。
  Future<void> _checkpoint(String id, int generation) {
    return _serializeExecution(() async {
      _currentExecutionTask(id, generation);
      final pending = _progressDirty;
      await _persistTasks(_progressClock());
      if (pending) {
        _lastProgressNotifyAt = _progressClock();
        notifyListeners();
      }
    });
  }

  Future<void> _persistTasks(int now) async {
    await repository.save(tasks);
    _progressDirty = false;
    _lastProgressSaveAt = now;
  }

  Future<void> _setVerifying(String id, int generation) {
    return _serializeExecution(() async {
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
    _retryAttempts.remove(id);
    return _serializeExecution(() async {
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
      await _serializeExecution(() async {
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
    final code = classifyDownloadFailureCode(error);
    final attempts = _retryAttempts[id] ?? 0;
    final retrying = code.isRetryable && attempts < maxAutomaticRetries;
    final retryCount = retrying ? attempts + 1 : attempts;
    if (retrying) {
      _retryAttempts[id] = retryCount;
    } else {
      _retryAttempts.remove(id);
    }
    try {
      await _serializeExecution(() async {
        final current = _currentExecutionTask(id, generation);
        await _commit({
          ..._tasks,
          id: current.copyWith(
            state: DownloadTaskState.failed,
            failure: DownloadFailure.fromMessage(
              code,
              error.toString(),
              retryCount: retryCount,
              httpStatus: downloadFailureHttpStatus(error),
            ),
            updatedAt: _clock(),
          ),
        });
      });
    } on DownloadCancelledException {
      // A newer task generation owns this identifier.
      _retryAttempts.remove(id);
      return;
    }
    if (retrying) _scheduleAutomaticRetry(id, generation, retryCount);
  }

  /// 可重试的失败:任务先停在 failed(带 retryCount,UI 能看出在重试),
  /// 退避到点后自己回到队列;期间用户手动 retry / remove 会顶掉这一代任务。
  void _scheduleAutomaticRetry(String id, int generation, int attempt) {
    if (_disposed) return;
    _pendingRetries++;
    unawaited(_runAutomaticRetry(id, generation, attempt));
  }

  Future<void> _runAutomaticRetry(
    String id,
    int generation,
    int attempt,
  ) async {
    try {
      await _retryDelay(retryBackoffFor(attempt));
      if (_disposed || (_generations[id] ?? 0) != generation) return;
      await _serializeExecution(() async {
        final current = _tasks[id];
        if (current == null || current.state != DownloadTaskState.failed) {
          return;
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
    } finally {
      _pendingRetries--;
      _requestPump();
      _completeIdleIfSettled();
    }
  }

  /// 执行期(executor 回调与收尾)专用的串行写入。
  ///
  /// [_serialize] 在 dispose 之后以 StateError 完成 —— 那是给外部调用方的信号,
  /// 但在途任务的收尾没有人 await,抛出去就成了未捕获的异步异常。协调器已经
  /// 销毁时这些写入本就无处可去,静默丢弃即可。
  Future<void> _serializeExecution(Future<void> Function() action) async {
    if (_disposed) return;
    try {
      await _serialize(action);
    } on StateError {
      if (!_disposed) rethrow;
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

  /// 没有在途任务、没有待跑的调度、也没有排队等退避的自动重试。
  bool get _settled =>
      _active.isEmpty &&
      !_pumpRequested &&
      !_pumpRunning &&
      _pendingRetries == 0;

  void _completeIdleIfSettled() {
    if (!_settled) return;
    final completer = _idleCompleter;
    _idleCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> _commit(Map<String, DownloadTask> next) async {
    final frozen = Map<String, DownloadTask>.unmodifiable(next);
    await repository.save(_ordered(frozen.values));
    _tasks = frozen;
    // 状态迁移不节流:攒着的进度随这次写盘一起落地,节流窗口重新计时。
    _progressDirty = false;
    final now = _progressClock();
    _lastProgressSaveAt = now;
    _lastProgressNotifyAt = now;
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

/// 第 [attempt] 次自动重试的退避时长:1s、4s、16s……
Duration retryBackoffFor(int attempt) {
  final steps = attempt < 1 ? 0 : attempt - 1;
  return DownloadCoordinator.retryBackoffBase * (1 << (2 * steps));
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

/// 策略不允许下载时可被自动暂停的状态:排队中与下载中。
/// `verifying` 已经写完盘、只差校验,让它跑完比中断更省事。
bool _policyPausable(DownloadTaskState state) =>
    state == DownloadTaskState.queued || state == DownloadTaskState.running;

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
