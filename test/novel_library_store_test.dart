import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'lib.favorites': 'manga-data'});
    sandbox = await Directory.systemTemp.createTemp('novel-library-test-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('deserialization derives keys from validated identity fields', () {
    final entry = NovelLibraryEntry.fromJson({
      'key': 'remote:collision:target',
      'origin': 'remote',
      'sourceId': 'source',
      'novelId': 'actual',
      'title': '远程小说',
    });

    expect(entry.key, 'remote:source:actual');
    expect(
      () => NovelLibraryEntry.fromJson({
        'key': 'local:missing',
        'origin': 'localEpub',
        'title': '缺少指纹',
      }),
      throwsArgumentError,
    );
    expect(
      () => NovelLibraryEntry.fromJson({
        'key': 'remote:source:missing',
        'origin': 'remote',
        'sourceId': 'source',
        'title': '缺少作品 ID',
      }),
      throwsArgumentError,
    );
  });

  test('mismatched serialized keys cannot collide during load', () async {
    SharedPreferences.setMockInitialValues({
      'novel.library.v1': jsonEncode([
        {
          'key': 'remote:shared:key',
          'origin': 'remote',
          'sourceId': 'source',
          'novelId': 'first',
          'title': '第一本',
        },
        {
          'key': 'remote:shared:key',
          'origin': 'remote',
          'sourceId': 'source',
          'novelId': 'second',
          'title': '第二本',
        },
      ]),
    });
    final store = NovelLibraryStore();

    await store.load();

    expect(store.entries, hasLength(2));
    expect(store.entryFor('remote:source:first')?.title, '第一本');
    expect(store.entryFor('remote:source:second')?.title, '第二本');
    store.dispose();
  });

  test('load skips malformed records and repairs persisted collections',
      () async {
    SharedPreferences.setMockInitialValues({
      'novel.library.v1': jsonEncode([
        {
          'key': 'untrusted',
          'origin': 'remote',
          'sourceId': 'source',
          'novelId': 'valid',
          'title': '有效小说',
        },
        {'key': 'remote:broken', 'origin': 'remote', 'sourceId': 'source'},
        'not-a-record',
      ]),
      'novel.history.v1': jsonEncode({
        'remote:source:valid': {
          'chapterId': 'chapter-1',
          'fraction': .5,
          'updatedAt': 12,
        },
        'remote:source:broken': {'fraction': .8},
        'not-a-record': 7,
      }),
    });
    final store = NovelLibraryStore();

    await store.load();
    await store.flushPending();

    expect(store.entries, hasLength(1));
    expect(store.entryFor('remote:source:valid')?.title, '有效小说');
    expect(store.progressFor('remote:source:valid')?.fraction, .5);
    expect(store.progressFor('remote:source:broken'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(
        jsonDecode(prefs.getString('novel.library.v1')!) as List, hasLength(1));
    expect(
      jsonDecode(prefs.getString('novel.history.v1')!) as Map,
      hasLength(1),
    );
    store.dispose();
  });

  test('load rejects malformed outer collection types without losing defaults',
      () async {
    SharedPreferences.setMockInitialValues({
      'novel.library.v1': jsonEncode({'entry': 'wrong outer type'}),
      'novel.history.v1': jsonEncode(['wrong outer type']),
      'novel.settings.v1': jsonEncode(['wrong outer type']),
    });
    final store = NovelLibraryStore();

    await store.load();

    expect(store.entries, isEmpty);
    expect(store.progressFor('entry'), isNull);
    expect(store.preferences.mode, NovelReaderMode.paged);
    store.dispose();
  });

  test('local and remote entries persist in an independent namespace',
      () async {
    final localDirectory =
        Directory('${sandbox.path}${Platform.pathSeparator}abc');
    await localDirectory.create();
    final store = NovelLibraryStore();
    await store.load();
    store.addLocal(NovelLibraryEntry.local(
      sha256: 'abc',
      title: '本地小说',
      authors: const ['作者甲'],
      cover: '${localDirectory.path}${Platform.pathSeparator}cover.jpg',
      privatePath: localDirectory.path,
      origin: NovelOrigin.localTxt,
    ));
    store.toggleRemoteFavorite(NovelLibraryEntry.remote(
      sourceId: 's',
      novelId: 'n',
      title: '远程小说',
    ));
    store.saveProgress(
      'remote:s:n',
      const NovelLocator(chapterId: 'c1', blockId: 'p2', fraction: .4),
    );
    store.setPreferences(const NovelReaderPreferences(
      mode: NovelReaderMode.scroll,
      fontFamily: 'Test Font',
      fontSize: 20,
      lineHeight: 1.8,
      paragraphSpacing: 14,
      horizontalMargin: 28,
      theme: NovelReaderTheme.black,
      keepScreenOn: false,
    ));
    await store.flushPending();

    final restored = NovelLibraryStore();
    await restored.load();

    expect(restored.entries.length, 2);
    expect(restored.entryFor('local:abc')?.available, isTrue);
    expect(restored.entryFor('local:abc')?.origin, NovelOrigin.localTxt);
    expect(restored.entryFor('local:abc')?.privatePath, localDirectory.path);
    expect(
      restored.entryFor('local:abc')?.cover,
      '${localDirectory.path}${Platform.pathSeparator}cover.jpg',
    );
    expect(restored.entryFor('remote:s:n')?.favorite, isTrue);
    expect(restored.progressFor('remote:s:n')?.blockId, 'p2');
    expect(restored.progressFor('remote:s:n')?.fraction, .4);
    expect(restored.preferences.mode, NovelReaderMode.scroll);
    expect(restored.preferences.fontFamily, 'Test Font');
    expect(restored.preferences.fontSize, 20);
    expect(restored.preferences.lineHeight, 1.8);
    expect(restored.preferences.paragraphSpacing, 14);
    expect(restored.preferences.horizontalMargin, 28);
    expect(restored.preferences.theme, NovelReaderTheme.black);
    expect(restored.preferences.keepScreenOn, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getString('lib.favorites'),
      'manga-data',
    );
    store.dispose();
    restored.dispose();
  });

  test('progress waits for the debounce flush before persistence', () async {
    final store = NovelLibraryStore();
    await store.load();
    store.saveProgress(
      'remote:s:n',
      const NovelLocator(chapterId: 'c1', fraction: .25),
    );

    final beforeFlush = NovelLibraryStore();
    await beforeFlush.load();
    expect(beforeFlush.progressFor('remote:s:n'), isNull);

    await store.flushPending();
    final afterFlush = NovelLibraryStore();
    await afterFlush.load();
    expect(afterFlush.progressFor('remote:s:n')?.fraction, .25);
    store.dispose();
    beforeFlush.dispose();
    afterFlush.dispose();
  });

  test('sync export strips local file paths but keeps fingerprint', () async {
    final store = NovelLibraryStore();
    await store.load();
    store.addLocal(NovelLibraryEntry.local(
      sha256: 'abc',
      title: '本地小说',
      cover: r'D:\Books\covers\book.jpg',
      privatePath: r'D:\Books\book.epub',
    ));

    final data = store.exportData();
    final entry = (data['entries']! as List).single as Map;

    expect(entry, isNot(contains('path')));
    expect(entry, isNot(contains('cover')));
    expect(entry['fingerprint'], 'abc');
    store.dispose();
  });

  test('default export keeps remote cover URLs', () async {
    final store = NovelLibraryStore();
    await store.load();
    store.toggleRemoteFavorite(NovelLibraryEntry.remote(
      sourceId: 'source',
      novelId: 'novel',
      title: '远程小说',
      cover: 'https://example.com/cover.jpg',
    ));

    final entry = (store.exportData()['entries']! as List).single as Map;

    expect(entry['cover'], 'https://example.com/cover.jpg');
    store.dispose();
  });

  test('local availability is recomputed when a persisted path disappears',
      () async {
    final localDirectory =
        Directory('${sandbox.path}${Platform.pathSeparator}available');
    await localDirectory.create();
    final store = NovelLibraryStore();
    await store.load();
    store.addLocal(NovelLibraryEntry.local(
      sha256: 'missing',
      title: '待恢复小说',
      privatePath: localDirectory.path,
    ));
    await store.flushPending();
    expect(store.entryFor('local:missing')?.available, isTrue);
    await localDirectory.delete(recursive: true);

    final restored = NovelLibraryStore();
    await restored.load();

    expect(restored.entryFor('local:missing')?.title, '待恢复小说');
    expect(restored.entryFor('local:missing')?.available, isFalse);
    store.dispose();
    restored.dispose();
  });

  test('flushPending writes library history and settings snapshots', () async {
    final store = NovelLibraryStore();
    await store.load();
    store.addLocal(NovelLibraryEntry.local(
      sha256: 'flush',
      title: '等待落盘',
      privatePath: sandbox.path,
    ));
    store.saveProgress(
      'local:flush',
      const NovelLocator(chapterId: 'chapter', fraction: .3),
    );
    store
        .setPreferences(const NovelReaderPreferences(fontFamily: 'Flush Font'));

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('novel.library.v1', '[]');
    await prefs.setString('novel.history.v1', '{}');
    await prefs.setString('novel.settings.v1', '{}');
    await store.flushPending();

    final restored = NovelLibraryStore();
    await restored.load();
    expect(restored.entryFor('local:flush')?.title, '等待落盘');
    expect(restored.progressFor('local:flush')?.fraction, .3);
    expect(restored.preferences.fontFamily, 'Flush Font');
    store.dispose();
    restored.dispose();
  });

  test('progress auto-persists only the latest value after 600ms debounce',
      () async {
    final store = NovelLibraryStore();
    await store.load();
    store.saveProgress(
      'remote:s:n',
      const NovelLocator(chapterId: 'first', fraction: .1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));
    store.saveProgress(
      'remote:s:n',
      const NovelLocator(chapterId: 'latest', fraction: .9),
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));

    final beforeDebounce = NovelLibraryStore();
    await beforeDebounce.load();
    expect(beforeDebounce.progressFor('remote:s:n'), isNull);
    beforeDebounce.dispose();

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final afterDebounce = NovelLibraryStore();
    await afterDebounce.load();
    expect(afterDebounce.progressFor('remote:s:n')?.chapterId, 'latest');
    expect(afterDebounce.progressFor('remote:s:n')?.fraction, .9);
    store.dispose();
    afterDebounce.dispose();
  });

  test('load completes safely when the store is disposed while awaiting prefs',
      () async {
    SharedPreferences.setMockInitialValues({
      'novel.settings.v1': jsonEncode({'fontFamily': 'Disposed Font'}),
    });
    final store = NovelLibraryStore();

    final loading = store.load();
    store.dispose();

    await expectLater(loading, completes);
  });
}
