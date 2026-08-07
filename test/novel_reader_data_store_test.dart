import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_data.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_data_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late Directory support;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('novel-reader-data-test-');
    support = Directory('${sandbox.path}${Platform.pathSeparator}support');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('portable models use stable IDs and cap quote context', () {
    final long = List.filled(400, '文').join();
    final locator = NovelLocator(
      chapterId: 'chapter-1',
      blockId: 'block-7',
      charOffset: 23,
      quote: long,
      prefix: long,
      suffix: long,
      fraction: .4,
    );
    final bookmark = NovelBookmark.create(
      bookKey: 'remote:source:book',
      locator: locator,
      excerpt: long,
      createdAt: 100,
    );
    final sameBookmark = NovelBookmark.create(
      bookKey: 'remote:source:book',
      locator: locator,
      excerpt: long,
      createdAt: 100,
    );
    final annotation = NovelAnnotation.create(
      bookKey: 'remote:source:book',
      range: NovelAnnotationRange.fromSelection(
        NovelSelection(text: long, start: locator, end: locator),
      ),
      colorId: 'yellow',
      note: '用户笔记',
      createdAt: 101,
    );

    expect(bookmark.id, sameBookmark.id);
    expect(bookmark.locator.quote!.length, NovelReaderTextCaps.quote);
    expect(bookmark.locator.prefix!.length, NovelReaderTextCaps.context);
    expect(bookmark.locator.suffix!.length, NovelReaderTextCaps.context);
    expect(bookmark.excerpt.length, NovelReaderTextCaps.excerpt);
    expect(annotation.range.quote.length, NovelReaderTextCaps.quote);
    expect(annotation.note, '用户笔记');
    expect(annotation.updatedAt, 101);
    expect(jsonEncode(annotation.toJson()), isNot(contains(r'C:\')));

    final directRange = NovelAnnotationRange(
      start: locator,
      end: locator,
      quote: long,
    );
    final directJson = directRange.toJson();
    expect((directJson['quote'] as String).length, NovelReaderTextCaps.quote);
    expect(
      ((directJson['start'] as Map)['prefix'] as String).length,
      NovelReaderTextCaps.context,
    );
  });

  test('merge unions different IDs and uses LWW including tombstones', () {
    final localBookmark = _bookmark(id: 'bookmark-a', updatedAt: 10);
    final localAnnotation = _annotation(id: 'annotation-a', updatedAt: 20);
    final remoteBookmark = _bookmark(id: 'bookmark-b', updatedAt: 30);
    final deletedRemote = _annotation(
      id: 'annotation-a',
      updatedAt: 40,
      deletedAt: 40,
    );
    final local = NovelReaderBookData(
      bookKey: 'book-key',
      bookmarks: {localBookmark.id: localBookmark},
      annotations: {localAnnotation.id: localAnnotation},
    );
    final remote = NovelReaderBookData(
      bookKey: 'book-key',
      bookmarks: {remoteBookmark.id: remoteBookmark},
      annotations: {deletedRemote.id: deletedRemote},
    );

    final merged = mergeNovelReaderBookData(local, remote);

    expect(merged.bookmarks.keys, containsAll(['bookmark-a', 'bookmark-b']));
    expect(merged.annotations['annotation-a']!.deletedAt, 40);
    expect(merged.annotations['annotation-a']!.updatedAt, 40);

    final olderRemote = NovelReaderBookData(
      bookKey: 'book-key',
      bookmarks: {
        localBookmark.id: _bookmark(id: localBookmark.id, updatedAt: 5),
      },
    );
    expect(
      mergeNovelReaderBookData(local, olderRemote)
          .bookmarks[localBookmark.id]!
          .updatedAt,
      10,
    );
  });

  test('flush writes UTF-8 atomically and reloads per-book data', () async {
    final store = _store(support);
    addTearDown(store.dispose);
    final bookmark = _bookmark(
      id: 'bookmark-a',
      bookKey: '本地:作品',
      updatedAt: 10,
    );
    final data = NovelReaderBookData(
      bookKey: '本地:作品',
      bookmarks: {bookmark.id: bookmark},
    );

    store.saveBook(data);
    await store.flushPending();
    final file = await store.fileForBook(data.bookKey);

    expect(await file.exists(), isTrue);
    expect(await File('${file.path}.tmp').exists(), isFalse);
    expect(await file.readAsString(), contains('本地:作品'));

    final restored = _store(support);
    addTearDown(restored.dispose);
    final loaded = await restored.loadBook(data.bookKey);
    expect(loaded.bookmarks['bookmark-a']?.locator.chapterId, 'chapter-1');
  });

  test('load recovers a valid leftover temporary file', () async {
    final store = _store(support);
    addTearDown(store.dispose);
    final bookmark = _bookmark(
      id: 'bookmark-recovered',
      bookKey: 'recover-book',
      updatedAt: 12,
    );
    final data = NovelReaderBookData(
      bookKey: 'recover-book',
      bookmarks: {bookmark.id: bookmark},
    );
    final file = await store.fileForBook(data.bookKey);
    await file.parent.create(recursive: true);
    await File('${file.path}.tmp').writeAsString(
      jsonEncode(data.toJson()),
      flush: true,
    );

    final loaded = await store.loadBook(data.bookKey);

    expect(loaded.bookmarks, contains('bookmark-recovered'));
    expect(await file.exists(), isTrue);
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('corrupt primary is retained before starting empty', () async {
    final store = _store(support, clock: () => 9876);
    addTearDown(store.dispose);
    final file = await store.fileForBook('corrupt-book');
    await file.parent.create(recursive: true);
    await file.writeAsString('{broken', flush: true);

    final loaded = await store.loadBook('corrupt-book');

    expect(loaded.bookmarks, isEmpty);
    expect(loaded.annotations, isEmpty);
    expect(await file.exists(), isFalse);
    expect(
      await File('${file.path}.corrupt-9876').exists(),
      isTrue,
    );
  });
}

NovelReaderDataStore _store(
  Directory support, {
  int Function()? clock,
}) {
  return NovelReaderDataStore(
    applicationSupportDirectory: () async => support,
    writeDelay: const Duration(hours: 1),
    clock: clock,
  );
}

NovelBookmark _bookmark({
  required String id,
  String bookKey = 'book-key',
  required int updatedAt,
}) {
  return NovelBookmark(
    id: id,
    bookKey: bookKey,
    locator: const NovelLocator(
      chapterId: 'chapter-1',
      blockId: 'block-1',
      charOffset: 4,
      quote: '正文',
      prefix: '前文',
      suffix: '后文',
      fraction: .2,
    ),
    excerpt: '正文摘要',
    createdAt: 1,
    updatedAt: updatedAt,
  );
}

NovelAnnotation _annotation({
  required String id,
  required int updatedAt,
  int? deletedAt,
}) {
  const locator = NovelLocator(
    chapterId: 'chapter-1',
    blockId: 'block-1',
    charOffset: 4,
    quote: '正文',
    prefix: '前文',
    suffix: '后文',
  );
  return NovelAnnotation(
    id: id,
    bookKey: 'book-key',
    range: const NovelAnnotationRange(
      start: locator,
      end: locator,
      quote: '正文',
    ),
    colorId: 'yellow',
    createdAt: 1,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );
}
