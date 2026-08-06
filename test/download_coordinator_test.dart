import 'dart:async';

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
  _ControlledExecutor({this.failingIds = const {}});

  final Set<String> failingIds;
  final List<String> started = [];
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
    _releases[task.id] = Completer<void>();
    for (final waiter in _waiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    if (failingIds.contains(task.id)) throw StateError('failed ${task.id}');
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
