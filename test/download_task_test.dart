import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

void main() {
  test('task round trips without transport secrets', () {
    final task = DownloadTask(
      id: 'manga:source:book:chapter',
      kind: DownloadContentKind.manga,
      title: '测试漫画',
      itemTitle: '第 1 话',
      state: DownloadTaskState.queued,
      createdAt: 100,
      updatedAt: 100,
      completedBytes: 5,
      totalBytes: 10,
      priority: 7,
      payload: const {'sourceId': 'source', 'mangaId': 'book'},
    );

    final encoded = task.toJson();
    expect(encoded.keys, isNot(contains('headers')));
    expect(encoded.keys, isNot(contains('url')));
    expect(DownloadTask.fromJson(encoded), task);
    expect(task.progress, 0.5);
  });

  test('progress clamps invalid byte ratios', () {
    expect(
      taskFixture().copyWith(completedBytes: 150, totalBytes: 100).progress,
      1,
    );
    expect(taskFixture().copyWith(totalBytes: 0).progress, 0);
  });

  test('completed task requires a completion timestamp', () {
    expect(
      () => taskFixture().copyWith(
        state: DownloadTaskState.completed,
        clearCompletedAt: true,
      ),
      throwsArgumentError,
    );
  });

  test('rejects transport secrets recursively in payload', () {
    expect(
      () => taskFixture().copyWith(
        payload: const {
          'sourceId': 'source',
          'nested': {
            'Authorization': 'Bearer secret',
          },
        },
      ),
      throwsArgumentError,
    );
  });

  test('rejects unknown serialized enum values', () {
    final json = taskFixture().toJson()..['kind'] = 'audio';
    expect(() => DownloadTask.fromJson(json), throwsFormatException);
  });
}
