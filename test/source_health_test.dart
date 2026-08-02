import 'dart:async';

import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/novel_source.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_health.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';

class _MangaHealthSource implements MangaSource {
  _MangaHealthSource({this.items = const [], this.error, this.pending = false});

  final List<Manga> items;
  final Object? error;
  final bool pending;
  bool disposed = false;
  int discoveryCalls = 0;

  @override
  String get id => 'manga-health';
  @override
  String get name => 'Manga health';
  @override
  String get lang => 'zh';
  @override
  String get baseUrl => 'https://example.test';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;
  @override
  List<FilterDef> get filters => const [];
  @override
  List<SourceSection> get sections => const [];
  @override
  Future<Paged<Manga>> getDiscovery(int page, {Map<String, Object?>? filters}) {
    discoveryCalls++;
    if (pending) return Completer<Paged<Manga>>().future;
    if (error != null) return Future<Paged<Manga>>.error(error!);
    return Future.value(Paged(items));
  }

  @override
  void dispose() => disposed = true;

  @override
  Future<Paged<Manga>> getSection(String sectionId, int page) =>
      throw UnimplementedError();
  @override
  Future<Paged<Manga>> getSearch(String query, int page,
          {Map<String, Object?>? filters}) =>
      throw UnimplementedError();
  @override
  Future<Manga> getMangaDetail(String mangaId) => throw UnimplementedError();
  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) =>
      throw UnimplementedError();
  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) =>
      throw UnimplementedError();
  @override
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) =>
      throw UnimplementedError();
  @override
  Future<SourceLogin> login(String username, String password) =>
      throw UnimplementedError();
}

class _NovelHealthSource implements NovelSource {
  _NovelHealthSource({this.items = const [], this.error, this.pending = false});

  final List<Novel> items;
  final Object? error;
  final bool pending;
  bool disposed = false;
  int discoveryCalls = 0;

  @override
  String get id => 'novel-health';
  @override
  String get name => 'Novel health';
  @override
  List<FilterDef> get filters => const [];
  @override
  List<SourceSection> get sections => const [];
  @override
  Future<Paged<Novel>> getNovelDiscovery(int page,
      {Map<String, Object?>? filters}) {
    discoveryCalls++;
    if (pending) return Completer<Paged<Novel>>().future;
    if (error != null) return Future<Paged<Novel>>.error(error!);
    return Future.value(Paged(items));
  }

  @override
  void dispose() => disposed = true;

  @override
  Future<Paged<Novel>> getNovelSection(String sectionId, int page) =>
      throw UnimplementedError();
  @override
  Future<Paged<Novel>> getNovelSearch(String query, int page,
          {Map<String, Object?>? filters}) =>
      throw UnimplementedError();
  @override
  Future<Novel> getNovelDetail(String novelId) => throw UnimplementedError();
  @override
  Future<Paged<NovelChapter>> getNovelChapters(String novelId, {int? page}) =>
      throw UnimplementedError();
  @override
  Future<NovelDocument> getNovelDocument(String novelId, String chapterId) =>
      throw UnimplementedError();
}

void main() {
  const qidian = SourceMeta(
    id: 'qidian',
    name: '起点中文网',
    script: '/* qidian */',
    kind: 'novel',
  );
  const manga = SourceMeta(id: 'manga', name: '漫画源', script: '/* manga */');

  test('checks Qidian-shaped novel metadata through novel discovery', () async {
    final source = _NovelHealthSource(items: const [
      Novel(id: '1', title: '宿命之环', cover: 'https://cover/1'),
      Novel(id: '2', title: '诡秘之主'),
      Novel(id: '3', title: '深空彼岸', cover: 'https://cover/3'),
      Novel(id: '4', title: '夜的命名术'),
      Novel(id: '5', title: '灵境行者'),
      Novel(id: '6', title: '赤心巡天'),
    ]);
    var mangaBuilderCalled = false;

    final result = await checkSourceHealth(
      qidian,
      mangaBuilder: (_) {
        mangaBuilderCalled = true;
        throw StateError('manga builder must not run');
      },
      novelBuilder: (_) => source,
    );

    expect(result.status, SourceHealthStatus.ok);
    expect(result.count, 6);
    expect(result.log, contains('测试:getNovelDiscovery(1)'));
    expect(result.log, contains('发现 6 部(其中 2 部带封面)'));
    expect(result.log, contains('示例:宿命之环、诡秘之主、深空彼岸、夜的命名术、灵境行者'));
    expect(source.discoveryCalls, 1);
    expect(source.disposed, isTrue);
    expect(mangaBuilderCalled, isFalse);
  });

  test('checks manga metadata through manga discovery', () async {
    final source = _MangaHealthSource(
      items: const [Manga(id: '1', title: '漫画', cover: 'https://cover/1')],
    );
    var novelBuilderCalled = false;

    final result = await checkSourceHealth(
      manga,
      mangaBuilder: (_) => source,
      novelBuilder: (_) {
        novelBuilderCalled = true;
        throw StateError('novel builder must not run');
      },
    );

    expect(result.status, SourceHealthStatus.ok);
    expect(result.log, contains('测试:getDiscovery(1)'));
    expect(source.discoveryCalls, 1);
    expect(source.disposed, isTrue);
    expect(novelBuilderCalled, isFalse);
  });

  test('rejects unknown metadata kind before building a source', () async {
    var mangaBuilderCalled = false;
    var novelBuilderCalled = false;
    const unknown = SourceMeta(
      id: 'unknown',
      name: '未知源',
      script: '',
      kind: 'podcast',
    );

    final result = await checkSourceHealth(
      unknown,
      mangaBuilder: (_) {
        mangaBuilderCalled = true;
        throw StateError('unexpected');
      },
      novelBuilder: (_) {
        novelBuilderCalled = true;
        throw StateError('unexpected');
      },
    );

    expect(result.status, SourceHealthStatus.fail);
    expect(result.log, contains('expected manga, anime, or novel'));
    expect(mangaBuilderCalled, isFalse);
    expect(novelBuilderCalled, isFalse);
  });

  test('reports an empty discovery result and disposes the source', () async {
    final source = _MangaHealthSource();

    final result = await checkSourceHealth(manga, mangaBuilder: (_) => source);

    expect(result.status, SourceHealthStatus.empty);
    expect(result.count, 0);
    expect(source.disposed, isTrue);
  });

  test('reports network-like errors and disposes the novel source', () async {
    final source =
        _NovelHealthSource(error: TimeoutException('connection reset'));

    final result = await checkSourceHealth(qidian, novelBuilder: (_) => source);

    expect(result.status, SourceHealthStatus.fail);
    expect(result.log, contains('connection reset'));
    expect(source.disposed, isTrue);
  });

  test('reports timeout and disposes the manga source', () async {
    final source = _MangaHealthSource(pending: true);

    final result = await checkSourceHealth(
      manga,
      timeout: const Duration(milliseconds: 1),
      mangaBuilder: (_) => source,
    );

    expect(result.status, SourceHealthStatus.fail);
    expect(result.log, contains('TimeoutException'));
    expect(source.disposed, isTrue);
  });
}
