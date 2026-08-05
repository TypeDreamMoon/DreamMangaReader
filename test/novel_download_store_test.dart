import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/app/novel_download_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/novel_document_cache.dart';
import 'package:dream_manga_reader/core/novel/novel_source.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNovelSource implements NovelSource {
  Object? error;
  bool disposed = false;
  Completer<void>? documentStarted;
  Future<void>? documentGate;

  @override
  String get id => 'source';

  @override
  String get name => '小说源';

  @override
  List<FilterDef> get filters => const [];

  @override
  List<SourceSection> get sections => const [];

  @override
  void dispose() => disposed = true;

  @override
  Future<Paged<NovelChapter>> getNovelChapters(String novelId, {int? page}) {
    throw UnimplementedError();
  }

  @override
  Future<Paged<Novel>> getNovelDiscovery(int page,
      {Map<String, Object?>? filters}) {
    throw UnimplementedError();
  }

  @override
  Future<Novel> getNovelDetail(String novelId) {
    throw UnimplementedError();
  }

  @override
  Future<NovelDocument> getNovelDocument(
    String novelId,
    String chapterId,
  ) async {
    final started = documentStarted;
    if (started != null && !started.isCompleted) started.complete();
    final gate = documentGate;
    if (gate != null) await gate;
    final failure = error;
    if (failure != null) throw failure;
    return NovelDocument(
      format: NovelDocumentFormat.html,
      content: '<p>离线正文 $chapterId</p>',
    );
  }

  @override
  Future<Paged<Novel>> getNovelSearch(String query, int page,
      {Map<String, Object?>? filters}) {
    throw UnimplementedError();
  }

  @override
  Future<Paged<Novel>> getNovelSection(String sectionId, int page) {
    throw UnimplementedError();
  }
}

void main() {
  late Directory temp;
  late _FakeNovelSource source;
  const meta = SourceMeta(
    id: 'source',
    name: '小说源',
    script: '',
    kind: 'novel',
  );
  const novel = Novel(id: 'novel', title: '测试小说');
  const chapter = NovelChapter(id: 'chapter', title: '第一章');

  NovelDownloadStore makeStore() => NovelDownloadStore(
        rootProvider: () async => temp.path,
        sourceBuilder: (_) => source,
        cacheFactory: (root) => NovelDocumentCache(root: root, dio: Dio()),
      );

  test('downloaded source metadata preserves a shared auth key', () {
    const sourceWithSharedAuth = SourceMeta(
      id: 'xiaojie_novel',
      name: '晓桀小说',
      script: 'source code',
      kind: 'novel',
      needsLogin: true,
      authKey: 'xiaojie_github',
    );
    final record = DownloadedNovelChapter(
      source: sourceWithSharedAuth,
      novel: novel,
      chapter: chapter,
      directory: 'chapter-directory',
      resourceCount: 2,
      byteCount: 128,
      completedAt: 100,
    );

    final restored = DownloadedNovelChapter.fromJson(record.toJson());

    expect(restored.source.authKey, 'xiaojie_github');
    expect(restored.source.credentialKey, 'xiaojie_github');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('novel-download-test-');
    source = _FakeNovelSource();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('download stores a complete offline chapter and survives reload',
      () async {
    final store = makeStore();
    await store.load();

    store.enqueue(meta, novel, chapter);
    await store.idle;

    expect(store.isDownloaded('source', 'novel', 'chapter'), isTrue);
    expect(await store.localDocument('source', 'novel', 'chapter'), isNotNull);
    expect(source.disposed, isTrue);

    source = _FakeNovelSource();
    final restored = makeStore();
    await restored.load();
    expect(restored.isDownloaded('source', 'novel', 'chapter'), isTrue);
    expect(
        await restored.localDocument('source', 'novel', 'chapter'), isNotNull);
    store.dispose();
    restored.dispose();
  });

  test('failed chapter is retryable and never marked complete', () async {
    final store = makeStore();
    await store.load();
    source.error = Exception('network');

    store.enqueue(meta, novel, chapter);
    await store.idle;

    expect(store.isDownloaded('source', 'novel', 'chapter'), isFalse);
    expect(store.failureOf('source', 'novel', 'chapter'), isNotNull);

    source = _FakeNovelSource();
    store.retry('source', 'novel', 'chapter');
    await store.idle;
    expect(store.isDownloaded('source', 'novel', 'chapter'), isTrue);
    expect(store.failureOf('source', 'novel', 'chapter'), isNull);
    store.dispose();
  });

  test('delete novel removes its records and complete cache', () async {
    final store = makeStore();
    await store.load();
    store.enqueue(meta, novel, chapter);
    await store.idle;

    await store.deleteNovel('source', 'novel');

    expect(store.isDownloaded('source', 'novel', 'chapter'), isFalse);
    expect(await store.localDocument('source', 'novel', 'chapter'), isNull);
    store.dispose();
  });

  test('deleting an active chapter cannot uncancel it when re-enqueued',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final queuedStarted = Completer<void>();
    final queuedRelease = Completer<void>();
    final first = _FakeNovelSource()
      ..documentStarted = started
      ..documentGate = release.future;
    final queued = _FakeNovelSource()
      ..documentStarted = queuedStarted
      ..documentGate = queuedRelease.future;
    final second = _FakeNovelSource()..error = Exception('second failed');
    final sources = [first, queued, second];
    const queuedChapter = NovelChapter(id: 'queued', title: '等待章节');
    final store = NovelDownloadStore(
      rootProvider: () async => temp.path,
      sourceBuilder: (_) => sources.removeAt(0),
      cacheFactory: (root) => NovelDocumentCache(root: root, dio: Dio()),
    );
    await store.load();

    store.enqueue(meta, novel, chapter);
    await started.future;
    store.enqueue(meta, novel, queuedChapter);
    await store.deleteChapter('source', 'novel', 'chapter');
    store.enqueue(meta, novel, chapter);
    release.complete();
    await queuedStarted.future;

    expect(store.progressOf('source', 'novel', 'chapter'), isNotNull);
    queuedRelease.complete();
    await store.idle;

    expect(store.isDownloaded('source', 'novel', 'chapter'), isFalse);
    expect(store.failureOf('source', 'novel', 'chapter'), isNotNull);
    expect(first.disposed, isTrue);
    expect(queued.disposed, isTrue);
    expect(second.disposed, isTrue);
    store.dispose();
  });

  test('active downloads expose their novel and chapter metadata', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    source
      ..documentStarted = started
      ..documentGate = release.future;
    final store = makeStore();
    await store.load();

    store.enqueue(meta, novel, chapter);
    await started.future;

    expect(store.activities, hasLength(1));
    expect(store.activities.single.novel.title, '测试小说');
    expect(store.activities.single.chapter.title, '第一章');
    expect(store.activities.single.progress, .2);

    release.complete();
    await store.idle;
    expect(store.activities, isEmpty);
    store.dispose();
  });
}
