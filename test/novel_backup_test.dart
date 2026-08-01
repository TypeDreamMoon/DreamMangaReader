import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/app/backup.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('novel-backup-test-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('backup includes novel metadata and progress but no local path or bytes',
      () async {
    final manga = LibraryStore();
    final novels = NovelLibraryStore();
    await novels.load();
    final privateDirectory = Directory(
      '${sandbox.path}${Platform.pathSeparator}original.epub',
    );
    await privateDirectory.create();
    novels.addLocal(NovelLibraryEntry.local(
      sha256: 'ABC',
      title: '本地小说',
      privatePath: privateDirectory.path,
      origin: NovelOrigin.localEpub,
    ));
    novels.saveProgress(
      'local:abc',
      const NovelLocator(chapterId: 'c9', blockId: 'p4', fraction: .4),
      updatedAt: 88,
    );

    final backup = buildBackupData(manga, novels);
    final encoded = jsonEncode(backup);

    expect(backup['novels'], isA<Map>());
    expect(encoded, contains('local:abc'));
    expect(encoded, contains('c9'));
    expect(encoded, isNot(contains(sandbox.path)));
    expect(encoded, isNot(contains('original.epub')));
    manga.dispose();
    novels.dispose();
  });

  test('backup restore reattaches an existing local path by fingerprint',
      () async {
    final manga = LibraryStore();
    final novels = NovelLibraryStore();
    await novels.load();
    final directory = Directory(
      '${sandbox.path}${Platform.pathSeparator}private-copy',
    );
    await directory.create();
    novels.addLocal(NovelLibraryEntry.local(
      sha256: 'same',
      title: '本机旧标题',
      privatePath: directory.path,
      origin: NovelOrigin.localTxt,
    ));
    final backup = <String, dynamic>{
      'v': 1,
      'novels': {
        'schema': 1,
        'entries': [
          {
            'key': 'local:same',
            'origin': 'localTxt',
            'fingerprint': 'same',
            'title': '云端新标题',
            'authors': ['作者'],
            'favorite': true,
            'addedAt': 20,
          },
        ],
        'history': {
          'local:same': {
            'chapterId': 'c2',
            'fraction': .25,
            'updatedAt': 50,
          },
        },
        'settings': const NovelReaderPreferences().toJson(),
      },
    };

    await restoreBackupData(manga, novels, backup);

    expect(novels.entryFor('local:same')?.title, '云端新标题');
    expect(novels.entryFor('local:same')?.privatePath, directory.path);
    expect(novels.entryFor('local:same')?.available, isTrue);
    expect(novels.progressFor('local:same')?.chapterId, 'c2');
    manga.dispose();
    novels.dispose();
  });
}
