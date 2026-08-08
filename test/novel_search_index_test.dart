import 'dart:io';

import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_search_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late NovelSearchIndex index;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dmr-search-index-');
    index = NovelSearchIndex(rootDirectory: () async => directory);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('Chinese substring results stream in chapter order with context',
      () async {
    final events = await index
        .search(
          bookKey: 'local:book',
          sourceFingerprint: 'v1',
          chapters: _chapters(2),
          query: '神秘',
          loadCachedDocument: (chapter) async => switch (chapter.id) {
            'c1' => _text('开头文字。神秘事件第一次出现。结尾文字。'),
            _ => _html('<p>第二章也有神秘线索。</p>'),
          },
        )
        .toList();

    final batches = events.whereType<NovelSearchResultBatch>().toList();
    expect(batches, hasLength(2));
    final results = batches.expand((event) => event.results).toList();
    expect(results.map((result) => result.chapterId), ['c1', 'c2']);
    expect(results.first.snippet, contains('神秘'));
    expect(results.first.locator.chapterId, 'c1');
    expect(results.first.locator.charOffset, greaterThan(0));
    expect(events.last, isA<NovelSearchCompleted>());
  });

  test('cancel token receives a terminal cancellation acknowledgement',
      () async {
    final cancellation = NovelSearchCancellationToken();
    final events = <NovelSearchEvent>[];
    await for (final event in index.search(
      bookKey: 'local:cancel',
      sourceFingerprint: 'v1',
      chapters: _chapters(40),
      query: '目标',
      cancellation: cancellation,
      loadCachedDocument: (chapter) async =>
          _text('${chapter.title}${'填充' * 2000}目标'),
    )) {
      events.add(event);
      if (event is NovelSearchResultBatch) cancellation.cancel();
    }

    expect(events.last, isA<NovelSearchCancelled>());
  });

  test('changed chapters rebuild and obsolete chapter files are removed',
      () async {
    final first = {
      'c1': _text('旧内容'),
      'c2': _text('即将删除'),
    };
    await index
        .search(
          bookKey: 'local:changed',
          sourceFingerprint: 'v1',
          chapters: _chapters(2),
          query: '旧内容',
          loadCachedDocument: (chapter) async => first[chapter.id],
        )
        .drain<void>();

    final secondEvents = await index
        .search(
          bookKey: 'local:changed',
          sourceFingerprint: 'v2',
          chapters: _chapters(1),
          query: '新内容',
          loadCachedDocument: (_) async => _text('新内容'),
        )
        .toList();
    final results = secondEvents
        .whereType<NovelSearchResultBatch>()
        .expand((event) => event.results);

    expect(results, hasLength(1));
    final bookDirectory = await index.directoryForBook('local:changed');
    final chapterFiles = bookDirectory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.txt'));
    expect(chapterFiles, hasLength(1));
  });

  test('cached-only search never fetches and full-book search reports fetch',
      () async {
    var fetches = 0;
    Future<NovelDocument?> cached(NovelChapter chapter) async =>
        chapter.id == 'c1' ? _text('本地命中') : null;
    Future<NovelDocument> fetch(NovelChapter chapter) async {
      fetches++;
      return _text('远程命中');
    }

    final cachedEvents = await index
        .search(
          bookKey: 'remote:s:n1',
          sourceFingerprint: 'v1',
          chapters: _chapters(2),
          query: '命中',
          loadCachedDocument: cached,
          fetchMissing: false,
          fetchDocument: fetch,
        )
        .toList();
    expect(fetches, 0);
    expect(
      cachedEvents
          .whereType<NovelSearchResultBatch>()
          .expand((event) => event.results),
      hasLength(1),
    );

    final fullEvents = await index
        .search(
          bookKey: 'remote:s:n1',
          sourceFingerprint: 'v1',
          chapters: _chapters(2),
          query: '命中',
          loadCachedDocument: cached,
          fetchMissing: true,
          fetchDocument: fetch,
        )
        .toList();
    expect(fetches, 1);
    expect(fullEvents.whereType<NovelSearchProgress>().last.fetchedChapters, 1);
    expect(
      fullEvents
          .whereType<NovelSearchResultBatch>()
          .expand((event) => event.results),
      hasLength(2),
    );
  });
}

List<NovelChapter> _chapters(int count) => List.generate(
      count,
      (index) => NovelChapter(id: 'c${index + 1}', title: '第${index + 1}章'),
    );

NovelDocument _text(String value) => NovelDocument(
      format: NovelDocumentFormat.text,
      content: value,
    );

NovelDocument _html(String value) => NovelDocument(
      format: NovelDocumentFormat.html,
      content: value,
    );
