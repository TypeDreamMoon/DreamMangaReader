import 'dart:io';

import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_render_document.dart';
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

  test('results carry the block they landed in, not just a fraction', () async {
    final document = _text('\u7b2c\u4e00\u6bb5\u5f00\u5934\u3002\n\u7b2c\u4e8c\u6bb5\u91cc\u6709\u795e\u79d8\u4e8b\u4ef6\u3002\n\u7b2c\u4e09\u6bb5\u7ed3\u5c3e\u3002');
    final events = await index
        .search(
          bookKey: 'local:blocks',
          sourceFingerprint: 'v1',
          chapters: _chapters(1),
          query: '\u795e\u79d8',
          loadCachedDocument: (_) async => document,
        )
        .toList();
    final result = events
        .whereType<NovelSearchResultBatch>()
        .expand((event) => event.results)
        .single;

    // 没有 blockId 的 locator 会让分页器退化成按比例估算，开搜索结果会差好几页。
    expect(result.locator.blockId, isNotNull);

    final blocks = NovelRenderDocumentParser.parse(document).blocks;
    final block = blocks.firstWhere(
      (value) => value.id == result.locator.blockId,
    );
    final offset = result.locator.charOffset!;
    // charOffset 是块内偏移 —— 与 NovelPageFragment.sourceStart 同一坐标系。
    expect(
      block.plainText.substring(offset, offset + result.locator.quote!.length),
      '\u795e\u79d8',
    );
  });

  test('a changed source fingerprint rebuilds instead of reusing the index',
      () async {
    Future<void> run(String fingerprint, NovelDocument? cached) async {
      await index
          .search(
            bookKey: 'local:fingerprint',
            sourceFingerprint: fingerprint,
            chapters: _chapters(1),
            query: '\u795e\u79d8',
            loadCachedDocument: (_) async => cached,
          )
          .drain<void>();
    }

    Future<int> hits(String fingerprint) async {
      final events = await index
          .search(
            bookKey: 'local:fingerprint',
            sourceFingerprint: fingerprint,
            chapters: _chapters(1),
            query: '\u795e\u79d8',
            loadCachedDocument: (_) async => null,
          )
          .toList();
      return events
          .whereType<NovelSearchResultBatch>()
          .expand((event) => event.results)
          .length;
    }

    await run('v1', _text('\u795e\u79d8\u4e8b\u4ef6\u3002'));

    // 同一份正文：缓存照用。
    expect(await hits('v1'), 1);
    // manifest 里的 sourceFingerprint 以前只写不比，正文在线更新后会一直沿用旧索引。
    expect(await hits('v2'), 0);
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
