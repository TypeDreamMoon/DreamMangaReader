import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/app/novel_download_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/novel_document_cache.dart';
import 'package:dream_manga_reader/core/novel/novel_source.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/downloads/downloads_page.dart';
import 'package:dream_manga_reader/features/novel/novel_downloads_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Source implements NovelSource {
  _Source({this.error});

  final Object? error;

  @override
  String get id => 'novel-source';

  @override
  String get name => '小说源';

  @override
  List<FilterDef> get filters => const [];

  @override
  List<SourceSection> get sections => const [];

  @override
  void dispose() {}

  @override
  Future<NovelDocument> getNovelDocument(
      String novelId, String chapterId) async {
    if (error case final value?) throw value;
    return NovelDocument(
      format: NovelDocumentFormat.text,
      content: '离线正文 $chapterId',
    );
  }

  @override
  Future<Paged<NovelChapter>> getNovelChapters(String novelId, {int? page}) =>
      throw UnimplementedError();

  @override
  Future<Paged<Novel>> getNovelDiscovery(int page,
          {Map<String, Object?>? filters}) =>
      throw UnimplementedError();

  @override
  Future<Novel> getNovelDetail(String novelId) => throw UnimplementedError();

  @override
  Future<Paged<Novel>> getNovelSearch(String query, int page,
          {Map<String, Object?>? filters}) =>
      throw UnimplementedError();

  @override
  Future<Paged<Novel>> getNovelSection(String sectionId, int page) =>
      throw UnimplementedError();
}

void main() {
  late Directory sandbox;
  late NovelDownloadStore store;
  var source = _Source();
  const meta = SourceMeta(
    id: 'novel-source',
    name: '小说源',
    script: '',
    kind: 'novel',
  );
  const novel = Novel(id: 'novel-1', title: '小说下载甲');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('novel-downloads-ui-');
    source = _Source();
    store = NovelDownloadStore(
      rootProvider: () async => sandbox.path,
      sourceBuilder: (_) => source,
      cacheFactory: (root) => NovelDocumentCache(root: root, dio: Dio()),
    );
    await store.load();
  });

  tearDown(() async {
    store.dispose();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  testWidgets('novel downloads group chapters and show stored bytes',
      (tester) async {
    await tester.runAsync(() async {
      store.enqueue(
        meta,
        novel,
        const NovelChapter(id: 'c1', title: '第一章'),
      );
      await store.idle;
    });

    await tester.pumpWidget(_harness(store));

    expect(find.text('小说下载甲'), findsWidgets);
    expect(find.textContaining('1 章'), findsOneWidget);
    expect(find.textContaining('B'), findsOneWidget);
  });

  testWidgets('failed novel download exposes retry', (tester) async {
    source = _Source(error: Exception('network'));
    await tester.runAsync(() async {
      store.enqueue(
        meta,
        novel,
        const NovelChapter(id: 'c2', title: '第二章'),
      );
      await store.idle;
    });

    await tester.pumpWidget(_harness(store));

    expect(find.textContaining('1 项失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('download kind switch never mixes manga and novel records',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _SwitchHarness()));

    expect(find.text('漫画下载'), findsOneWidget);
    expect(find.text('小说下载'), findsNothing);
    await tester.tap(find.text('小说'));
    await tester.pump();
    expect(find.text('小说下载'), findsOneWidget);
    expect(find.text('漫画下载'), findsNothing);
  });
}

Widget _harness(NovelDownloadStore store) {
  return MaterialApp(
    theme: buildTheme(AppThemeVariant.light),
    home: NovelDownloadScope(
      store: store,
      child: const Scaffold(body: NovelDownloadsView()),
    ),
  );
}

class _SwitchHarness extends StatefulWidget {
  const _SwitchHarness();

  @override
  State<_SwitchHarness> createState() => _SwitchHarnessState();
}

class _SwitchHarnessState extends State<_SwitchHarness> {
  var kind = DownloadKind.manga;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: DownloadKindSwitch(
          selected: kind,
          onSelected: (value) => setState(() => kind = value),
        ),
      ),
      body:
          kind == DownloadKind.manga ? const Text('漫画下载') : const Text('小说下载'),
    );
  }
}
