import 'package:dream_manga_reader/core/downloads/download_executor.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancellation prevents later work', () {
    final cancellation = DownloadCancellation();
    cancellation.cancel();

    expect(cancellation.isCancelled, isTrue);
    expect(
      cancellation.throwIfCancelled,
      throwsA(isA<DownloadCancelledException>()),
    );
  });

  test('progress remains monotonic and total never falls below completed',
      () async {
    final updates = <(int, int)>[];
    final context = DownloadExecutionContext(
      cancellation: DownloadCancellation(),
      reportProgress: (completed, total) async {
        updates.add((completed, total));
      },
      checkpoint: () async {},
    );

    await context.reportProgress(30, 100);
    await context.reportProgress(20, 10);

    expect(updates, [(30, 100), (30, 100)]);
  });

  test('negative progress is rejected', () async {
    final context = DownloadExecutionContext(
      cancellation: DownloadCancellation(),
      reportProgress: (_, __) async {},
      checkpoint: () async {},
    );

    expect(() => context.reportProgress(-1, 10), throwsArgumentError);
    expect(() => context.reportProgress(1, -1), throwsArgumentError);
  });

  test('checkpoint observes cancellation', () async {
    var checkpoints = 0;
    final cancellation = DownloadCancellation();
    final context = DownloadExecutionContext(
      cancellation: cancellation,
      reportProgress: (_, __) async {},
      checkpoint: () async => checkpoints++,
    );

    await context.checkpoint();
    cancellation.cancel();

    expect(context.checkpoint, throwsA(isA<DownloadCancelledException>()));
    expect(checkpoints, 1);
  });

  test('executor declares one content kind', () {
    expect(_MangaExecutor().kind, DownloadContentKind.manga);
  });
}

final class _MangaExecutor implements DownloadExecutor {
  @override
  DownloadContentKind get kind => DownloadContentKind.manga;

  @override
  Future<void> execute(
    DownloadExecutionContext context,
    DownloadTask task,
  ) async {}
}
