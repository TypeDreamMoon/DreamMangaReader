import 'dart:io';

import 'package:dream_manga_reader/app/anime_download_store.dart';
import 'package:dream_manga_reader/app/download_coordinator_scope.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/downloads/content_download_task.dart';
import 'package:dream_manga_reader/core/downloads/download_coordinator.dart';
import 'package:dream_manga_reader/core/downloads/download_executor.dart';
import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/anime_downloads_view.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

/// 番剧下载只能增不能删:store 从来没有 delete,协调器的 `remove()` 又只删任务记录、
/// 不回调执行器 —— 落盘的 `segment-*.bin` 和包目录会永远留着。这一组钉住删除路径。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('anime-delete-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('delete wipes the package directory, the index entry and the task',
      () async {
    final store = _store(root);
    await store.load();
    addTearDown(store.dispose);
    final coordinator = _coordinator();
    await coordinator.load();
    addTearDown(coordinator.dispose);
    final task = _task('episode-1', '第一集');
    await coordinator.enqueue(task);

    await store.execute(_context(), task);
    expect(store.isDownloaded('source', 'show', 'episode-1'), isTrue);
    expect(_packageDirectories(root), hasLength(1));

    await store.delete('source', 'show', 'episode-1',
        coordinator: coordinator);

    expect(store.isDownloaded('source', 'show', 'episode-1'), isFalse);
    expect(store.downloads, isEmpty);
    expect(_packageDirectories(root), isEmpty);
    expect(coordinator.task(task.id), isNull);

    // 索引也真的写回去了:重开一次仍然是空的。
    final reopened = _store(root);
    await reopened.load();
    addTearDown(reopened.dispose);
    expect(reopened.downloads, isEmpty);
  });

  test('delete also clears the leftovers of a cancelled download', () async {
    // 取消的任务从没进过索引,但它已经写下的分片同样占着磁盘。
    final cancellation = DownloadCancellation();
    final store = _store(root, cancelAfterFirstSegment: cancellation);
    await store.load();
    addTearDown(store.dispose);

    await expectLater(
      store.execute(
        _context(cancellation: cancellation),
        _task('episode-1', '第一集'),
      ),
      throwsA(isA<DownloadCancelledException>()),
    );
    final leftovers = _packageDirectories(root);
    expect(leftovers, hasLength(1));
    expect(
      leftovers.single.listSync().whereType<File>().map(
            (file) => file.uri.pathSegments.last,
          ),
      contains('segment-0.bin'),
    );
    expect(store.isDownloaded('source', 'show', 'episode-1'), isFalse);

    await store.delete('source', 'show', 'episode-1');

    expect(_packageDirectories(root), isEmpty);
  });

  test('deleteSeries removes every downloaded episode of one show', () async {
    final store = _store(root);
    await store.load();
    addTearDown(store.dispose);
    await store.execute(_context(), _task('episode-1', '第一集'));
    await store.execute(_context(), _task('episode-2', '第二集'));
    expect(store.downloads, hasLength(2));
    expect(_packageDirectories(root), hasLength(2));

    await store.deleteSeries('source', 'show');

    expect(store.downloads, isEmpty);
    expect(_packageDirectories(root), isEmpty);
  });

  testWidgets('long pressing an episode deletes it after confirmation',
      (tester) async {
    final store = _store(root);
    final coordinator = _coordinator();
    addTearDown(store.dispose);
    addTearDown(coordinator.dispose);
    // 协调器的队列跑在 fake async 上,store 的落盘要真实事件循环 —— 两者不能塞进
    // 同一个 runAsync,否则协调器那条 `Future.value()` 链永远排不上队。
    await coordinator.load();
    await tester.runAsync(store.load);
    await tester.runAsync(
      () => store.execute(_context(), _task('episode-1', '第一集')),
    );

    await tester.pumpWidget(_app(store, coordinator));
    expect(find.text('第一集'), findsOneWidget);

    await tester.longPress(
      find.byKey(Key('anime-download-episode-${store.downloads.single.key}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除下载'), findsOneWidget);

    await tester.tap(find.byKey(const Key('anime-download-delete-confirm')));
    await _settleWithDiskIo(tester);

    expect(store.downloads, isEmpty);
    expect(find.text('暂无已下载番剧'), findsOneWidget);
    expect(find.text('已删除本地缓存'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the series button deletes every episode after confirmation',
      (tester) async {
    final store = _store(root);
    final coordinator = _coordinator();
    addTearDown(store.dispose);
    addTearDown(coordinator.dispose);
    await coordinator.load();
    await tester.runAsync(store.load);
    await tester.runAsync(() async {
      await store.execute(_context(), _task('episode-1', '第一集'));
      await store.execute(_context(), _task('episode-2', '第二集'));
    });

    await tester.pumpWidget(_app(store, coordinator));
    expect(find.text('第二集'), findsOneWidget);

    await tester
        .tap(find.byKey(const Key('anime-download-delete-series-show')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('anime-download-delete-confirm')));
    await _settleWithDiskIo(tester);

    expect(store.downloads, isEmpty);
    expect(_packageDirectories(root), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 删除要真的落到磁盘上,而 widget 测试跑在 fake async 里 —— 只 pump 的话,
/// `Directory.delete` 的回调永远排不上队。让真实事件循环转几圈,再把 fake 队列排干。
Future<void> _settleWithDiskIo(WidgetTester tester) async {
  for (var round = 0; round < 40; round++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 400));
}

Widget _app(AnimeDownloadStore store, DownloadCoordinator coordinator) =>
    MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: DownloadCoordinatorScope(
        coordinator: coordinator,
        child: AnimeDownloadScope(
          store: store,
          child: const Scaffold(body: AnimeDownloadsView()),
        ),
      ),
    );

AnimeDownloadStore _store(
  Directory root, {
  DownloadCancellation? cancelAfterFirstSegment,
}) =>
    AnimeDownloadStore(
      rootProvider: () async => root.path,
      trackProvider: (_, __, ___) async => const [
        VideoTrack(
          url: 'https://video.test/index.m3u8',
          quality: '1080P',
          hls: true,
        ),
      ],
      upstream: _FakeUpstream(cancelAfterFirstSegment),
    );

DownloadCoordinator _coordinator() => DownloadCoordinator(
      repository: RecordingDownloadTaskRepository(),
      environment: () async => unrestrictedEnvironment,
      settings: DownloadPolicySettings.new,
    );

DownloadTask _task(String episodeId, String episodeTitle) =>
    ContentDownloadTask.anime(
      sourceId: 'source',
      contentId: 'show',
      contentTitle: '测试番剧',
      chapterId: episodeId,
      chapterTitle: episodeTitle,
      now: 1,
    );

DownloadExecutionContext _context({DownloadCancellation? cancellation}) =>
    DownloadExecutionContext(
      cancellation: cancellation ?? DownloadCancellation(),
      reportProgress: (_, __) async {},
      checkpoint: () async {},
    );

List<Directory> _packageDirectories(Directory root) =>
    root.listSync().whereType<Directory>().toList(growable: false);

class _FakeUpstream implements HlsUpstreamClient {
  _FakeUpstream(this.cancelAfterFirstSegment);

  /// 非 null 时:第二个分片一开口就取消,模拟「下到一半被撤掉」。
  final DownloadCancellation? cancelAfterFirstSegment;
  int _segments = 0;

  @override
  Future<HlsUpstreamResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    int? rangeStart,
    int? rangeLength,
  }) async {
    if (uri.path.endsWith('.m3u8')) {
      return HlsUpstreamResponse(
        statusCode: 200,
        bytes: '#EXTM3U\n'
                '#EXT-X-TARGETDURATION:4\n'
                '#EXT-X-PLAYLIST-TYPE:VOD\n'
                '#EXTINF:4,\n'
                'one.ts\n'
                '#EXTINF:4,\n'
                'two.ts\n'
                '#EXT-X-ENDLIST\n'
            .codeUnits,
        headers: const {},
      );
    }
    _segments++;
    if (_segments > 1) cancelAfterFirstSegment?.cancel();
    return const HlsUpstreamResponse(
      statusCode: 200,
      bytes: [1, 2, 3],
      headers: {},
    );
  }
}
