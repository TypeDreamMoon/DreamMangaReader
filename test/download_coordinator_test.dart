import 'dart:async';
import 'dart:io';

import 'package:dream_manga_reader/core/downloads/download_coordinator.dart';
import 'package:dream_manga_reader/core/downloads/download_executor.dart';
import 'package:dream_manga_reader/core/downloads/download_failure.dart';
import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

void main() {
  late RecordingDownloadTaskRepository repository;
  late DownloadCoordinator coordinator;
  var now = 1000;

  setUp(() {
    repository = RecordingDownloadTaskRepository();
    coordinator = DownloadCoordinator(
      repository: repository,
      environment: () async => unrestrictedEnvironment,
      settings: DownloadPolicySettings.new,
      clock: () => now++,
    );
  });

  tearDown(() => coordinator.dispose());

  test('load exposes tasks in priority and creation order', () async {
    repository.loaded = [
      taskFixture(id: 'low', priority: 1),
      taskFixture(id: 'new', priority: 2).copyWith(createdAt: 200),
      taskFixture(id: 'old', priority: 2).copyWith(createdAt: 100),
    ];

    await coordinator.load();

    expect(coordinator.tasks.map((task) => task.id), ['old', 'new', 'low']);
  });

  test('enqueue persists before notifying listeners', () async {
    await coordinator.load();
    var persistedWhenNotified = false;
    coordinator.addListener(() {
      persistedWhenNotified = repository.saved.isNotEmpty;
    });

    final task = taskFixture();
    await coordinator.enqueue(task);

    expect(persistedWhenNotified, isTrue);
    expect(repository.saved.single, contains(task));
    expect(coordinator.tasks, contains(task));
  });

  test('duplicate task ids are rejected', () async {
    await coordinator.load();
    await coordinator.enqueue(taskFixture());

    expect(() => coordinator.enqueue(taskFixture()), throwsStateError);
  });

  test('completed imports are atomic and idempotent', () async {
    await coordinator.load();
    final completed = taskFixture(
      id: 'legacy:manga:chapter',
      state: DownloadTaskState.completed,
    );

    await coordinator.importCompleted([completed]);
    await coordinator.importCompleted([completed]);

    expect(coordinator.task(completed.id), completed);
    expect(repository.saved, hasLength(1));
    expect(repository.saved.single, [completed]);
  });

  test('completed imports reconcile an unfinished matching task', () async {
    final queued = taskFixture(id: 'content:manga:chapter');
    final completed = taskFixture(
      id: queued.id,
      state: DownloadTaskState.completed,
    );
    repository.loaded = [queued];
    await coordinator.load();

    await coordinator.importCompleted([completed]);

    expect(coordinator.task(queued.id), completed);
    expect(repository.saved.last, [completed]);
  });

  test('completed imports reject active tasks', () async {
    await coordinator.load();

    expect(
      () => coordinator.importCompleted([taskFixture()]),
      throwsArgumentError,
    );
    expect(repository.saved, isEmpty);
  });

  test('pause and resume preserve a user pause reason', () async {
    await coordinator.load();
    final task = taskFixture();
    await coordinator.enqueue(task);

    await coordinator.pause(task.id);
    expect(coordinator.task(task.id)!.state, DownloadTaskState.paused);
    expect(
      coordinator.task(task.id)!.pauseReason,
      DownloadPauseReason.user,
    );

    await coordinator.resume(task.id);
    expect(coordinator.task(task.id)!.state, DownloadTaskState.queued);
    expect(coordinator.task(task.id)!.pauseReason, isNull);
  });

  test('completed task cannot resume and pauseAll preserves it', () async {
    repository.loaded = [
      taskFixture(id: 'queued'),
      taskFixture(id: 'done', state: DownloadTaskState.completed),
    ];
    await coordinator.load();

    await coordinator.pauseAll();

    expect(coordinator.task('queued')!.state, DownloadTaskState.paused);
    expect(coordinator.task('done')!.state, DownloadTaskState.completed);
    expect(() => coordinator.resume('done'), throwsStateError);
  });

  test('retry clears failure and returns task to queue', () async {
    repository.loaded = [
      taskFixture().copyWith(
        state: DownloadTaskState.failed,
        failure: const DownloadFailure(
          code: DownloadFailureCode.network,
          message: '网络错误',
          detail: 'timeout',
          retryCount: 1,
        ),
      ),
    ];
    await coordinator.load();

    await coordinator.retry(taskFixture().id);

    final retried = coordinator.task(taskFixture().id)!;
    expect(retried.state, DownloadTaskState.queued);
    expect(retried.failure, isNull);
  });

  test('reorder updates stable ordering and remove deletes the task', () async {
    repository.loaded = [
      taskFixture(id: 'first', priority: 1),
      taskFixture(id: 'second', priority: 0),
    ];
    await coordinator.load();

    await coordinator.reorder('second', 3);
    expect(coordinator.tasks.first.id, 'second');

    await coordinator.remove('second');
    expect(coordinator.task('second'), isNull);
    expect(repository.saved.last.map((task) => task.id), ['first']);
  });

  test('restart returns transient states to queued', () async {
    final runningTask = taskFixture(state: DownloadTaskState.running);
    final verifyingTask = taskFixture(
      id: 'novel:source:book:chapter',
      kind: DownloadContentKind.novel,
      state: DownloadTaskState.verifying,
    );
    final completedTask = taskFixture(
      id: 'anime:source:show:episode',
      kind: DownloadContentKind.anime,
      state: DownloadTaskState.completed,
    );
    repository.loaded = [runningTask, verifyingTask, completedTask];

    await coordinator.load();

    expect(coordinator.task(runningTask.id)!.state, DownloadTaskState.queued);
    expect(
      coordinator.task(verifyingTask.id)!.state,
      DownloadTaskState.queued,
    );
    expect(
      coordinator.task(completedTask.id)!.state,
      DownloadTaskState.completed,
    );
    expect(repository.saved, isNotEmpty);
  });

  test('scheduler starts higher priority first with bounded concurrency',
      () async {
    repository.loaded = [
      taskFixture(id: 'low', priority: 0),
      taskFixture(id: 'high', priority: 3),
      taskFixture(id: 'middle', priority: 2),
    ];
    final executor = _ControlledExecutor();
    await coordinator.load();
    coordinator.registerExecutor(executor);

    await executor.waitForStarted(2);

    expect(executor.started, ['high', 'middle']);
    expect(coordinator.task('low')!.state, DownloadTaskState.queued);
    executor.complete('high');
    await executor.waitForStarted(3);
    expect(executor.started.last, 'low');
    executor.completeAll();
    await coordinator.idle;
    expect(
      coordinator.tasks.every(
        (task) => task.state == DownloadTaskState.completed,
      ),
      isTrue,
    );
  });

  test('one executor failure does not stop another queued task', () async {
    repository.loaded = [taskFixture(id: 'bad'), taskFixture(id: 'good')];
    final executor = _ControlledExecutor(failingIds: {'bad'});
    await coordinator.load();
    coordinator.registerExecutor(executor);

    await executor.waitForStarted(2);
    executor.complete('good');
    await coordinator.idle;

    expect(coordinator.task('bad')!.state, DownloadTaskState.failed);
    expect(coordinator.task('good')!.state, DownloadTaskState.completed);
  });

  test('policy-paused tasks return to queue after reevaluation', () async {
    var currentEnvironment = unrestrictedEnvironment.copyWith(wifi: false);
    coordinator.dispose();
    coordinator = DownloadCoordinator(
      repository: repository,
      environment: () async => currentEnvironment,
      settings: DownloadPolicySettings.new,
      clock: () => now++,
    );
    repository.loaded = [taskFixture()];
    await coordinator.load();

    await coordinator.reevaluate();
    expect(coordinator.tasks.single.state, DownloadTaskState.paused);
    expect(coordinator.tasks.single.pauseReason, DownloadPauseReason.wifi);

    currentEnvironment = unrestrictedEnvironment;
    await coordinator.reevaluate();
    expect(coordinator.tasks.single.state, DownloadTaskState.queued);
    expect(coordinator.tasks.single.pauseReason, isNull);
  });

  test('progress stays in memory between throttled saves', () async {
    var wall = 0;
    coordinator.dispose();
    coordinator = DownloadCoordinator(
      repository: repository,
      environment: () async => unrestrictedEnvironment,
      settings: DownloadPolicySettings.new,
      clock: () => now++,
      progressClock: () => wall,
    );
    final executor = _ControlledExecutor();
    await coordinator.load();
    coordinator.registerExecutor(executor);
    await coordinator.enqueue(taskFixture());
    await executor.waitForStarted(1);
    final context = executor.contexts[taskFixture().id]!;

    repository.saved.clear();
    var notifications = 0;
    coordinator.addListener(() => notifications++);

    for (var tick = 1; tick <= 10; tick++) {
      wall = tick * 100;
      await context.reportProgress(tick, 100);
    }

    // 1s 内 10 次进度:一次盘都不写,通知也只在 500ms / 1000ms 各发一次。
    expect(repository.saved, isEmpty);
    expect(notifications, 2);
    expect(coordinator.task(taskFixture().id)!.completedBytes, 10);

    wall = 2500;
    await context.reportProgress(11, 100);
    expect(repository.saved, hasLength(1));
    expect(repository.saved.single.single.completedBytes, 11);

    // checkpoint 绕过节流,立刻落盘。
    wall = 2600;
    await context.reportProgress(12, 100);
    expect(repository.saved, hasLength(1));
    await context.checkpoint();
    expect(repository.saved, hasLength(2));
    expect(repository.saved.last.single.completedBytes, 12);

    executor.complete(taskFixture().id);
    await coordinator.idle;
    expect(
      coordinator.task(taskFixture().id)!.state,
      DownloadTaskState.completed,
    );
  });

  test('retryable failures back off and give up after three retries',
      () async {
    final delays = <Duration>[];
    coordinator.dispose();
    coordinator = DownloadCoordinator(
      repository: repository,
      environment: () async => unrestrictedEnvironment,
      settings: DownloadPolicySettings.new,
      clock: () => now++,
      retryDelay: (duration) async => delays.add(duration),
    );
    final executor = _ControlledExecutor(
      failingIds: {taskFixture().id},
      errors: {taskFixture().id: const SocketException('connection reset')},
    );
    await coordinator.load();
    coordinator.registerExecutor(executor);
    await coordinator.enqueue(taskFixture());
    await coordinator.idle;

    expect(delays, const [
      Duration(seconds: 1),
      Duration(seconds: 4),
      Duration(seconds: 16),
    ]);
    expect(executor.started, hasLength(4));
    final failed = coordinator.task(taskFixture().id)!;
    expect(failed.state, DownloadTaskState.failed);
    expect(failed.failure!.code, DownloadFailureCode.network);
    expect(failed.failure!.retryCount, 3);

    // 手动重试重新发一份重试预算。
    delays.clear();
    executor.started.clear();
    await coordinator.retry(taskFixture().id);
    await coordinator.idle;
    expect(delays, hasLength(3));
    expect(executor.started, hasLength(4));
  });

  test('non retryable failures stop at the first attempt', () async {
    final delays = <Duration>[];
    coordinator.dispose();
    coordinator = DownloadCoordinator(
      repository: repository,
      environment: () async => unrestrictedEnvironment,
      settings: DownloadPolicySettings.new,
      clock: () => now++,
      retryDelay: (duration) async => delays.add(duration),
    );
    final executor = _ControlledExecutor(
      failingIds: {taskFixture().id},
      errors: {
        taskFixture().id: const FileSystemException(
          'write failed',
          '/pages/0.img',
          OSError('No space left on device', 28),
        ),
      },
    );
    await coordinator.load();
    coordinator.registerExecutor(executor);
    await coordinator.enqueue(taskFixture());
    await coordinator.idle;

    expect(delays, isEmpty);
    expect(executor.started, hasLength(1));
    final failed = coordinator.task(taskFixture().id)!;
    expect(failed.state, DownloadTaskState.failed);
    expect(failed.failure!.code, DownloadFailureCode.insufficientStorage);
    expect(failed.failure!.retryCount, 0);
  });

  test('in-flight executor results after dispose are dropped silently',
      () async {
    final executor = _ControlledExecutor();
    await coordinator.load();
    coordinator.registerExecutor(executor);
    await coordinator.enqueue(taskFixture(id: 'failing'));
    await coordinator.enqueue(taskFixture(id: 'succeeding'));
    await executor.waitForStarted(2);

    coordinator.dispose();
    executor.failLate('failing', const SocketException('connection reset'));
    executor.complete('succeeding');
    await pumpEventQueue();

    // 重新装一个,tearDown 才有活对象可 dispose。
    coordinator = DownloadCoordinator(
      repository: repository,
      environment: () async => unrestrictedEnvironment,
      settings: DownloadPolicySettings.new,
      clock: () => now++,
    );
  });

  test('pauseAll cancels running tasks like pause does', () async {
    final executor = _ControlledExecutor();
    await coordinator.load();
    coordinator.registerExecutor(executor);
    await coordinator.enqueue(taskFixture());
    await executor.waitForStarted(1);

    await coordinator.pauseAll();

    expect(
      executor.contexts[taskFixture().id]!.cancellation.isCancelled,
      isTrue,
    );
    final paused = coordinator.task(taskFixture().id)!;
    expect(paused.state, DownloadTaskState.paused);
    expect(paused.pauseReason, DownloadPauseReason.user);

    executor.completeAll();
    await coordinator.idle;
    expect(coordinator.task(taskFixture().id)!.state, DownloadTaskState.paused);
  });

  test('policy pause cancels a running task and keeps its progress', () async {
    var currentEnvironment = unrestrictedEnvironment;
    coordinator.dispose();
    coordinator = DownloadCoordinator(
      repository: repository,
      environment: () async => currentEnvironment,
      settings: DownloadPolicySettings.new,
      clock: () => now++,
    );
    final executor = _ControlledExecutor();
    await coordinator.load();
    coordinator.registerExecutor(executor);
    await coordinator.enqueue(taskFixture().copyWith(completedBytes: 30));
    await executor.waitForStarted(1);

    currentEnvironment = unrestrictedEnvironment.copyWith(wifi: false);
    await coordinator.reevaluate();

    expect(executor.contexts[taskFixture().id]!.cancellation.isCancelled,
        isTrue);
    final paused = coordinator.task(taskFixture().id)!;
    expect(paused.state, DownloadTaskState.paused);
    expect(paused.pauseReason, DownloadPauseReason.wifi);
    expect(paused.completedBytes, 30);

    executor.completeAll();
    await coordinator.idle;
    expect(coordinator.task(taskFixture().id)!.state, DownloadTaskState.paused);
  });

  test('removing a running task invalidates late executor callbacks', () async {
    final executor = _ControlledExecutor();
    await coordinator.load();
    coordinator.registerExecutor(executor);
    await coordinator.enqueue(taskFixture());
    await executor.waitForStarted(1);

    await coordinator.remove(taskFixture().id);
    executor.complete(taskFixture().id);
    await coordinator.idle;

    expect(coordinator.task(taskFixture().id), isNull);
  });
}

final class _ControlledExecutor implements DownloadExecutor {
  _ControlledExecutor({this.failingIds = const {}, this.errors = const {}});

  final Set<String> failingIds;
  final Map<String, Object> errors;
  final List<String> started = [];
  final Map<String, DownloadExecutionContext> contexts = {};
  final Map<String, Completer<void>> _releases = {};
  final List<Completer<void>> _waiters = [];

  @override
  DownloadContentKind get kind => DownloadContentKind.manga;

  @override
  Future<void> execute(
    DownloadExecutionContext context,
    DownloadTask task,
  ) async {
    started.add(task.id);
    contexts[task.id] = context;
    _releases[task.id] = Completer<void>();
    for (final waiter in _waiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    if (failingIds.contains(task.id)) {
      throw errors[task.id] ?? StateError('failed ${task.id}');
    }
    await _releases[task.id]!.future;
    context.cancellation.throwIfCancelled();
    await context.reportProgress(100, 100);
  }

  Future<void> waitForStarted(int count) async {
    while (started.length < count) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
      _waiters.remove(waiter);
    }
  }

  void failLate(String id, Object error) {
    final release = _releases[id];
    if (release != null && !release.isCompleted) release.completeError(error);
  }

  void complete(String id) {
    final release = _releases[id];
    if (release != null && !release.isCompleted) release.complete();
  }

  void completeAll() {
    for (final release in _releases.values) {
      if (!release.isCompleted) release.complete();
    }
  }
}
