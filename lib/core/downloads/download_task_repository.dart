import 'dart:convert';
import 'dart:io';

import 'download_task.dart';

abstract interface class DownloadTaskRepository {
  Future<List<DownloadTask>> load();
  Future<void> save(List<DownloadTask> tasks);
}

final class FileDownloadTaskRepository implements DownloadTaskRepository {
  FileDownloadTaskRepository({
    required this.rootProvider,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const schemaVersion = 1;

  final Future<String> Function() rootProvider;
  final int Function() _clock;

  @override
  Future<List<DownloadTask>> load() async {
    final files = await _files();
    final candidates = [files.index, files.temporary, files.previous];
    for (final candidate in candidates) {
      if (!await candidate.exists()) continue;
      try {
        final tasks = await _read(candidate);
        if (candidate.path != files.index.path) {
          await save(tasks);
        }
        return tasks;
      } on Object {
        await _quarantine(candidate);
      }
    }
    return const [];
  }

  @override
  Future<void> save(List<DownloadTask> tasks) async {
    final files = await _files();
    final document = <String, Object?>{
      'schemaVersion': schemaVersion,
      'tasks': tasks.map((task) => task.toJson()).toList(growable: false),
    };
    await files.temporary.writeAsString(
      jsonEncode(document),
      encoding: utf8,
      flush: true,
    );

    if (await files.previous.exists()) await files.previous.delete();
    if (await files.index.exists())
      await files.index.rename(files.previous.path);
    try {
      await files.temporary.rename(files.index.path);
    } on Object {
      if (await files.previous.exists() && !await files.index.exists()) {
        await files.previous.rename(files.index.path);
      }
      rethrow;
    }
    if (await files.previous.exists()) await files.previous.delete();
  }

  Future<_RepositoryFiles> _files() async {
    final root = Directory(await rootProvider());
    await root.create(recursive: true);
    final index = File('${root.path}${Platform.pathSeparator}index.json');
    return _RepositoryFiles(
      index: index,
      temporary: File('${index.path}.tmp'),
      previous: File('${index.path}.previous'),
    );
  }

  Future<List<DownloadTask>> _read(File file) async {
    final decoded = jsonDecode(await file.readAsString(encoding: utf8));
    if (decoded is! Map) throw const FormatException('invalid task index');
    final document = decoded.cast<String, Object?>();
    if (document['schemaVersion'] != schemaVersion) {
      throw const FormatException('unsupported task index schema');
    }
    final rawTasks = document['tasks'];
    if (rawTasks is! List) throw const FormatException('invalid task list');
    return List<DownloadTask>.unmodifiable(
      rawTasks.map((value) {
        if (value is! Map) throw const FormatException('invalid task entry');
        return DownloadTask.fromJson(value.cast<String, Object?>());
      }),
    );
  }

  Future<void> _quarantine(File file) async {
    if (!await file.exists()) return;
    final target = File('${file.path}.corrupt-${_clock()}');
    if (await target.exists()) await target.delete();
    await file.rename(target.path);
  }
}

final class _RepositoryFiles {
  const _RepositoryFiles({
    required this.index,
    required this.temporary,
    required this.previous,
  });

  final File index;
  final File temporary;
  final File previous;
}
