import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/core/downloads/download_failure.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:dream_manga_reader/core/downloads/download_task_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

void main() {
  late Directory root;
  late FileDownloadTaskRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-task-repository-');
    repository = FileDownloadTaskRepository(
      rootProvider: () async => root.path,
      clock: () => 1234,
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('empty repository loads no tasks', () async {
    expect(await repository.load(), isEmpty);
  });

  test('save replaces the index atomically and preserves order', () async {
    final tasks = [
      taskFixture(id: 'novel:2', kind: DownloadContentKind.novel),
      taskFixture(id: 'manga:1'),
    ];

    await repository.save(tasks);

    final index = File('${root.path}/index.json');
    expect(await index.exists(), isTrue);
    expect(await File('${index.path}.tmp').exists(), isFalse);
    expect(await File('${index.path}.previous').exists(), isFalse);
    expect(await repository.load(), tasks);
  });

  test('stored bytes contain no signed URL or authorization value', () async {
    final failure = const DownloadFailure(
      code: DownloadFailureCode.network,
      message: '网络错误',
      detail: 'Authorization: Bearer secret\nhttps://cdn.test/a?token=secret',
      retryCount: 1,
    );

    await repository.save([
      taskFixture().copyWith(
        state: DownloadTaskState.failed,
        failure: failure,
      ),
    ]);

    final stored = await File('${root.path}/index.json').readAsString();
    expect(stored, isNot(contains('Bearer secret')));
    expect(stored, isNot(contains('token=secret')));
  });

  test('recovers valid temporary index when primary is missing', () async {
    final task = taskFixture();
    await File('${root.path}/index.json.tmp').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'tasks': [task.toJson()],
      }),
      flush: true,
    );

    expect(await repository.load(), [task]);
    expect(await File('${root.path}/index.json').exists(), isTrue);
    expect(await File('${root.path}/index.json.tmp').exists(), isFalse);
  });

  test('quarantines malformed primary and recovers previous index', () async {
    final task = taskFixture();
    await File('${root.path}/index.json').writeAsString('{broken');
    await File('${root.path}/index.json.previous').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'tasks': [task.toJson()],
      }),
      flush: true,
    );

    expect(await repository.load(), [task]);
    expect(await File('${root.path}/index.json.corrupt-1234').exists(), isTrue);
  });

  test('unsupported schema is quarantined and returns empty', () async {
    await File('${root.path}/index.json').writeAsString(
      jsonEncode({'schemaVersion': 99, 'tasks': const []}),
      flush: true,
    );

    expect(await repository.load(), isEmpty);
    expect(await File('${root.path}/index.json.corrupt-1234').exists(), isTrue);
  });
}
