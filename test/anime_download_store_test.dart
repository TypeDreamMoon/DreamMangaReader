import 'dart:io';

import 'package:dream_manga_reader/app/anime_download_store.dart';
import 'package:dream_manga_reader/core/downloads/download_executor.dart';
import 'package:dream_manga_reader/core/downloads/content_download_task.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('anime-offline-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('packages encrypted master playlist without upstream transport data',
      () async {
    final upstream = _FakeUpstream({
      'https://video.test/master.m3u8': _text('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=12000000,RESOLUTION=3840x2160
2160/index.m3u8
'''),
      'https://video.test/1080/index.m3u8': _text('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:4,
one.ts
#EXTINF:4,
two.ts
#EXT-X-ENDLIST
'''),
      'https://video.test/1080/key.bin':
          _bytes(List<int>.generate(16, (i) => i)),
      'https://video.test/1080/one.ts': _bytes([1, 2, 3]),
      'https://video.test/1080/two.ts': _bytes([4, 5]),
    });
    final progress = <(int, int)>[];

    final result = await AnimeHlsPackageWriter(upstream).write(
      playlistUri: Uri.parse('https://video.test/master.m3u8'),
      headers: const {'Authorization': 'secret-token'},
      directory: root,
      context: _context(progress),
    );

    final manifest = await result.manifest.readAsString();
    expect(upstream.requested, contains('https://video.test/1080/index.m3u8'));
    expect(upstream.requested,
        isNot(contains('https://video.test/2160/index.m3u8')));
    expect(manifest, isNot(contains('https://')));
    expect(manifest, isNot(contains('Authorization')));
    expect(manifest, isNot(contains('secret-token')));
    expect(manifest, contains('key-0.bin'));
    expect(manifest, contains('segment-0.bin'));
    expect(result.resourceCount, 3);
    expect(progress.last.$1, progress.last.$2);
  });

  test('materializes byte ranges and removes remote offsets', () async {
    final upstream = _FakeUpstream({
      'https://video.test/media.m3u8': _text('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="media.mp4",BYTERANGE="2@0"
#EXTINF:4,
#EXT-X-BYTERANGE:3@2
media.mp4
#EXT-X-ENDLIST
'''),
      'https://video.test/media.mp4': _bytes([10, 11, 12, 13, 14]),
    });

    final result = await AnimeHlsPackageWriter(upstream).write(
      playlistUri: Uri.parse('https://video.test/media.m3u8'),
      headers: const {},
      directory: root,
      context: _context([]),
    );

    final manifest = await result.manifest.readAsString();
    expect(manifest, isNot(contains('BYTERANGE')));
    expect(await File('${root.path}/init-0.bin').readAsBytes(), [10, 11]);
    expect(
        await File('${root.path}/segment-0.bin').readAsBytes(), [12, 13, 14]);
    expect(upstream.ranges, contains((0, 2)));
    expect(upstream.ranges, contains((2, 3)));
  });

  test('rejects live playlists without publishing a manifest', () async {
    final upstream = _FakeUpstream({
      'https://video.test/live.m3u8': _text('''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4,
live.ts
'''),
    });

    await expectLater(
      AnimeHlsPackageWriter(upstream).write(
        playlistUri: Uri.parse('https://video.test/live.m3u8'),
        headers: const {},
        directory: root,
        context: _context([]),
      ),
      throwsA(isA<UnsupportedAnimePlaylist>()),
    );
    expect(await File('${root.path}/index.m3u8').exists(), isFalse);
  });

  test('executor persists a completed episode and reloads it offline',
      () async {
    final upstream = _FakeUpstream({
      'https://video.test/episode.m3u8': _text('''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
episode.ts
#EXT-X-ENDLIST
'''),
      'https://video.test/episode.ts': _bytes([1, 2, 3, 4]),
    });
    Future<List<VideoTrack>> tracks(
      String sourceId,
      String animeId,
      String episodeId,
    ) async =>
        const [
          VideoTrack(
            url: 'https://video.test/episode.m3u8',
            quality: '自动',
            headers: {'Authorization': 'temporary'},
            hls: true,
          ),
        ];
    final store = AnimeDownloadStore(
      rootProvider: () async => root.path,
      trackProvider: tracks,
      upstream: upstream,
    );
    await store.load();
    final task = ContentDownloadTask.anime(
      sourceId: 'source',
      contentId: 'anime',
      contentTitle: '番剧',
      chapterId: 'episode',
      chapterTitle: '第一集',
      now: 1,
    );

    await store.execute(_context([]), task);

    expect(store.isDownloaded('source', 'anime', 'episode'), isTrue);
    final local = store.localManifest('source', 'anime', 'episode');
    expect(local, isNotNull);
    expect(await File(local!).exists(), isTrue);
    final index = await File('${root.path}/index.json').readAsString();
    expect(index, isNot(contains('https://')));
    expect(index, isNot(contains('temporary')));
    store.dispose();

    final reloaded = AnimeDownloadStore(
      rootProvider: () async => root.path,
      trackProvider: tracks,
      upstream: upstream,
    );
    await reloaded.load();
    expect(reloaded.downloads.single.episodeTitle, '第一集');
    expect(reloaded.localManifest('source', 'anime', 'episode'), local);
    reloaded.dispose();
  });
}

DownloadExecutionContext _context(List<(int, int)> progress) =>
    DownloadExecutionContext(
      cancellation: DownloadCancellation(),
      reportProgress: (completed, total) async {
        progress.add((completed, total));
      },
      checkpoint: () async {},
    );

HlsUpstreamResponse _text(String value) => HlsUpstreamResponse(
      statusCode: 200,
      bytes: value.trimLeft().codeUnits,
      headers: const {
        HttpHeaders.contentTypeHeader: ['application/vnd.apple.mpegurl'],
      },
    );

HlsUpstreamResponse _bytes(List<int> value) => HlsUpstreamResponse(
      statusCode: 200,
      bytes: value,
      headers: const {
        HttpHeaders.contentTypeHeader: ['application/octet-stream'],
      },
    );

class _FakeUpstream implements HlsUpstreamClient {
  _FakeUpstream(this.responses);

  final Map<String, HlsUpstreamResponse> responses;
  final List<String> requested = [];
  final List<(int, int)> ranges = [];

  @override
  Future<HlsUpstreamResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    int? rangeStart,
    int? rangeLength,
  }) async {
    requested.add(uri.toString());
    final response = responses[uri.toString()];
    if (response == null) throw StateError('Unexpected request: $uri');
    if (rangeStart != null && rangeLength != null) {
      ranges.add((rangeStart, rangeLength));
      return HlsUpstreamResponse(
        statusCode: response.statusCode,
        bytes: response.bytes.sublist(rangeStart, rangeStart + rangeLength),
        headers: response.headers,
      );
    }
    return response;
  }
}
