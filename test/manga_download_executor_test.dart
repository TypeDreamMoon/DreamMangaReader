import 'dart:io';

import 'package:dream_manga_reader/app/download_store.dart';
import 'package:dream_manga_reader/core/downloads/content_download_task.dart';
import 'package:dream_manga_reader/core/downloads/download_executor.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _onePixelPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  late Directory root;
  late List<SourceMeta> previousSources;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('manga-executor-');
    previousSources = registeredSources;
    registeredSources = const [
      SourceMeta(id: 'fake', name: '测试源', script: '', kind: 'manga'),
    ];
  });

  tearDown(() async {
    registeredSources = previousSources;
    await root.delete(recursive: true);
  });

  test('writes ordered pages, reports progress and updates legacy index',
      () async {
    final source = _FakeSource(const [
      PageImage(index: 0, url: _onePixelPng),
      PageImage(index: 1, url: _onePixelPng),
    ]);
    final store = DownloadStore(
      rootProvider: () async => root.path,
      sourceBuilder: (_) => source,
      pageFetcher: (_, __) async => throw StateError('network not expected'),
    );
    await store.load();
    final progress = <(int, int)>[];
    final task = ContentDownloadTask.manga(
      sourceId: 'fake',
      contentId: 'manga',
      contentTitle: '漫画',
      chapterId: 'chapter',
      chapterTitle: '第一话',
      now: 1,
    );

    await store.execute(
      DownloadExecutionContext(
        cancellation: DownloadCancellation(),
        reportProgress: (completed, total) async {
          progress.add((completed, total));
        },
        checkpoint: () async {},
      ),
      task,
    );

    expect(progress, [(1, 2), (2, 2)]);
    expect(store.isDownloaded('fake', 'manga', 'chapter'), isTrue);
    final pages = store.localPages('fake', 'manga', 'chapter')!;
    expect(pages, hasLength(2));
    expect(await Future.wait(pages.map((path) => File(path).exists())),
        everyElement(isTrue));
    store.dispose();
  });
}

class _FakeSource implements MangaSource {
  _FakeSource(this.pages);

  final List<PageImage> pages;

  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  String get lang => 'zh';
  @override
  String get baseUrl => '';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;
  @override
  List<FilterDef> get filters => const [];
  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) async =>
      pages;
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
