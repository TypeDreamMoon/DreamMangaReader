import 'dart:io';

import 'package:dream_manga_reader/app/anime_download_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/downloads/content_download_task.dart';
import 'package:dream_manga_reader/core/downloads/download_executor.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/anime_downloads_view.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('groups completed anime episodes by title', (tester) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('anime-view-test-'),
    ))!;
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = AnimeDownloadStore(
      rootProvider: () async => root.path,
      trackProvider: (_, __, ___) async => const [
        VideoTrack(
          url: 'https://video.test/index.m3u8',
          quality: '自动',
          hls: true,
        ),
      ],
      upstream: _ViewUpstream(),
    );
    await tester.runAsync(() async {
      await store.load();
      await store.execute(
        DownloadExecutionContext(
          cancellation: DownloadCancellation(),
          reportProgress: (_, __) async {},
          checkpoint: () async {},
        ),
        ContentDownloadTask.anime(
          sourceId: 'source',
          contentId: 'show',
          contentTitle: '测试番剧',
          chapterId: 'episode-1',
          chapterTitle: '第一集',
          now: 1,
        ),
      );
    });
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      home: AnimeDownloadScope(
        store: store,
        child: const Scaffold(body: AnimeDownloadsView()),
      ),
    ));

    expect(find.text('测试番剧'), findsOneWidget);
    expect(find.text('第一集'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _ViewUpstream implements HlsUpstreamClient {
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
        bytes: '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
episode.ts
#EXT-X-ENDLIST
'''
            .trimLeft()
            .codeUnits,
        headers: const {},
      );
    }
    return const HlsUpstreamResponse(
      statusCode: 200,
      bytes: [1, 2, 3],
      headers: {},
    );
  }
}
