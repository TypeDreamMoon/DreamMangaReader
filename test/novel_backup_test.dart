import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/app/backup.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_data.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_data_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

NovelReaderDataStore _readerStore(Directory directory) => NovelReaderDataStore(
      applicationSupportDirectory: () async => directory,
      writeDelay: const Duration(days: 1),
    );

Map<String, dynamic> _readerNotes(
  String bookKey, {
  required String itemId,
  required int updatedAt,
  String note = 'portable backup note',
}) =>
    {
      'schema': 1,
      'books': {
        bookKey: {
          'schema': 1,
          'bookKey': bookKey,
          'bookmarks': <String, dynamic>{},
          'annotations': {
            itemId: {
              'id': itemId,
              'bookKey': bookKey,
              'range': {
                'start': {'chapterId': 'chapter-1', 'charOffset': 1},
                'end': {'chapterId': 'chapter-1', 'charOffset': 5},
                'quote': 'quote',
              },
              'colorId': 'yellow',
              'createdAt': 1,
              'updatedAt': updatedAt,
              'note': note,
            },
          },
        },
      },
    };

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

  test('portable backup sanitizer removes device-only secrets recursively', () {
    const sentinel = 'DO_NOT_EXPORT_TOKEN_91f4';
    final sanitized = sanitizeBackupData({
      'v': 1,
      'sources.token': sentinel,
      'source.repository.token': sentinel,
      'auth.xiaojie_novel.token': sentinel,
      'nested': {
        'safe': 'keep-me',
        'auth.picacg.token': sentinel,
      },
      'items': [
        {'auth.xiaojie_anime.token': sentinel},
      ],
    });
    final encoded = jsonEncode(sanitized);

    expect(encoded, isNot(contains(sentinel)));
    expect(encoded, isNot(contains('sources.token')));
    expect(encoded, isNot(contains('source.repository.token')));
    expect(encoded, isNot(contains('auth.picacg.token')));
    expect((sanitized['nested'] as Map)['safe'], 'keep-me');
  });

  test('portable backup includes sanitized reader annotations recursively',
      () async {
    const bookKey = 'local:backup-book';
    const forbidden = 'DEVICE_ONLY_BACKUP_SENTINEL_d199';
    final manga = LibraryStore();
    final novels = NovelLibraryStore();
    await novels.load();
    final notes = _readerNotes(
      bookKey,
      itemId: 'annotation-1',
      updatedAt: 10,
    );
    final book = ((notes['books'] as Map)[bookKey] as Map);
    book['chapterText'] = forbidden;
    book['nested'] = {
      'bookText': forbidden,
      'searchIndex': forbidden,
      'privatePath': forbidden,
      'sourceToken': forbidden,
      'fontBytes': forbidden,
      'backgroundBytes': forbidden,
      'bgImage': forbidden,
      'pageScreenshot': forbidden,
    };

    final backup = buildBackupData(manga, novels, readerNotes: notes);
    final encoded = jsonEncode(backup);

    expect(((backup['novels'] as Map)['readerNotes']), isA<Map>());
    expect(encoded, contains('portable backup note'));
    expect(encoded, isNot(contains(forbidden)));
    for (final key in const [
      'chapterText',
      'bookText',
      'searchIndex',
      'privatePath',
      'sourceToken',
      'fontBytes',
      'backgroundBytes',
      'bgImage',
      'pageScreenshot',
    ]) {
      expect(encoded, isNot(contains(key)));
    }
    manga.dispose();
    novels.dispose();
  });

  test('backup restore appends then replaces reader notes and flushes',
      () async {
    const bookKey = 'local:restore-notes';
    const removedBook = 'local:removed-notes';
    final manga = LibraryStore();
    final novels = NovelLibraryStore();
    await novels.load();
    final store = _readerStore(sandbox);
    for (final entry in [
      (bookKey, 'local-note'),
      (removedBook, 'removed-note'),
    ]) {
      final notes = _readerNotes(entry.$1,
          itemId: entry.$2, updatedAt: 10, note: entry.$2);
      store.saveBook(NovelReaderBookData.fromJson(
        ((notes['books'] as Map)[entry.$1] as Map).cast<String, dynamic>(),
      ));
    }
    await store.flushPending();
    final appendNotes = _readerNotes(
      bookKey,
      itemId: 'remote-note',
      updatedAt: 20,
      note: 'remote note',
    );

    await restoreBackupData(
      manga,
      novels,
      {
        'v': 1,
        'novels': {'schema': 1, 'readerNotes': appendNotes},
      },
      readerDataStore: store,
      appendReaderNotes: true,
    );
    var persisted = _readerStore(sandbox);
    expect((await persisted.loadBook(bookKey)).annotations.keys,
        containsAll(['local-note', 'remote-note']));
    persisted.dispose();

    await restoreBackupData(
      manga,
      novels,
      {
        'v': 1,
        'novels': {'schema': 1, 'readerNotes': appendNotes},
      },
      readerDataStore: store,
      appendReaderNotes: false,
    );
    persisted = _readerStore(sandbox);
    expect((await persisted.loadBook(bookKey)).annotations.keys,
        equals({'remote-note'}));
    expect((await persisted.loadBook(removedBook)).annotations, isEmpty);
    persisted.dispose();
    store.dispose();
    manga.dispose();
    novels.dispose();
  });
}
