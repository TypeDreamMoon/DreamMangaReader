import 'package:dream_manga_reader/core/downloads/download_coordinator.dart';
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
}
