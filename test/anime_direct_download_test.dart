import 'dart:io';

import 'package:dream_manga_reader/app/anime_download_store.dart';
import 'package:dream_manga_reader/core/downloads/content_download_task.dart';
import 'package:dream_manga_reader/core/downloads/download_executor.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

/// B站番剧的轨道全都是 `hls: false`(DASH 分离流 / 老式 durl),而 store 以前只收
/// `track.hls`,于是每次点下载都抛「没有可下载的 HLS 轨道」—— 一集都下不了。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('anime-direct-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('downloads a DASH track together with its separate audio', () async {
    final upstream = _RangeUpstream({
      'https://cdn.test/1080.m4s': _bytes(600),
      'https://cdn.test/audio.m4s': _bytes(120),
    });
    final store = _store(root, upstream, const [
      VideoTrack(
        url: 'https://cdn.test/1080.m4s',
        audioUrl: 'https://cdn.test/audio.m4s',
        quality: '1080P',
        hls: false,
      ),
    ]);
    await store.load();
    addTearDown(store.dispose);

    await store.execute(_context(), _task());

    expect(store.isDownloaded('source', 'show', 'episode-1'), isTrue);
    final record = store.recordFor('source', 'show', 'episode-1')!;
    expect(record.mediaName, 'video.m4s');
    expect(record.audioName, 'audio.m4s');
    expect(File(record.mediaPath).lengthSync(), 600);
    expect(File(record.audioPath!).lengthSync(), 120);
    expect(record.byteCount, 720);
    expect(record.resourceCount, 2);

    // 重开一次,离线播放仍然指得到本地那两个文件。
    final reopened = _store(root, upstream, const []);
    await reopened.load();
    addTearDown(reopened.dispose);
    final restored = reopened.recordFor('source', 'show', 'episode-1')!;
    expect(restored.mediaPath, record.mediaPath);
    expect(restored.audioPath, record.audioPath);
  });

  test('downloads a plain durl mp4 without an audio file', () async {
    final upstream = _RangeUpstream({
      'https://cdn.test/full.mp4': _bytes(300),
    });
    final store = _store(root, upstream, const [
      VideoTrack(url: 'https://cdn.test/full.mp4', quality: '默认', hls: false),
    ]);
    await store.load();
    addTearDown(store.dispose);

    await store.execute(_context(), _task());

    final record = store.recordFor('source', 'show', 'episode-1')!;
    expect(record.mediaName, 'video.mp4');
    expect(record.audioName, isNull);
    expect(record.resourceCount, 1);
    expect(File(record.mediaPath).lengthSync(), 300);
  });

  test('prefers an HLS track when the source offers both', () async {
    final upstream = _RangeUpstream({
      'https://cdn.test/index.m3u8': _playlist(),
      'https://cdn.test/one.ts': _bytes(10),
      'https://cdn.test/full.mp4': _bytes(300),
    });
    final store = _store(root, upstream, const [
      VideoTrack(url: 'https://cdn.test/full.mp4', quality: '720P'),
      VideoTrack(
        url: 'https://cdn.test/index.m3u8',
        quality: '1080P',
        hls: true,
      ),
    ]);
    await store.load();
    addTearDown(store.dispose);

    await store.execute(_context(), _task());

    expect(store.recordFor('source', 'show', 'episode-1')!.mediaName,
        'index.m3u8');
  });

  test('greys the episode out when no track can be downloaded', () async {
    final store = _store(root, _RangeUpstream(const {}), const [
      // 空 url / 非 http 协议:下不了。
      VideoTrack(url: '', quality: '默认'),
      VideoTrack(url: 'blob:whatever', quality: '默认'),
    ]);
    await store.load();
    addTearDown(store.dispose);
    expect(store.isDownloadable('source', 'show', 'episode-1'), isTrue);

    await expectLater(
      store.execute(_context(), _task()),
      throwsA(isA<UnsupportedAnimePlaylist>()),
    );

    expect(store.isDownloadable('source', 'show', 'episode-1'), isFalse);
    expect(store.isDownloaded('source', 'show', 'episode-1'), isFalse);
  });

  group('AnimeFilePackageWriter', () {
    test('pulls a big file in ranged chunks', () async {
      final upstream = _RangeUpstream({
        'https://cdn.test/full.mp4': _bytes(10),
      });
      final result = await AnimeFilePackageWriter(upstream, chunkSize: 4).write(
        track: const VideoTrack(url: 'https://cdn.test/full.mp4'),
        headers: const {},
        directory: root,
        context: _context(),
      );

      expect(result.byteCount, 10);
      expect(upstream.ranges, [(0, 4), (4, 4), (8, 4)]);
      expect(
        File('${root.path}${Platform.pathSeparator}${result.mediaName}')
            .readAsBytesSync(),
        _bytes(10),
      );
    });

    test('resumes from the bytes a cancelled attempt already wrote', () async {
      const track = VideoTrack(url: 'https://cdn.test/full.mp4');
      final cancellation = DownloadCancellation();
      final interrupted = _RangeUpstream(
        {'https://cdn.test/full.mp4': _bytes(10)},
        cancelAfterChunks: 1,
        cancellation: cancellation,
      );
      await expectLater(
        AnimeFilePackageWriter(interrupted, chunkSize: 4).write(
          track: track,
          headers: const {},
          directory: root,
          context: _context(cancellation: cancellation),
        ),
        throwsA(isA<DownloadCancelledException>()),
      );
      // 第一块已经落盘,断点就在这里。
      expect(
        File('${root.path}${Platform.pathSeparator}video.mp4.part')
            .lengthSync(),
        4,
      );

      final resumed = _RangeUpstream({'https://cdn.test/full.mp4': _bytes(10)});
      final result = await AnimeFilePackageWriter(resumed, chunkSize: 4).write(
        track: track,
        headers: const {},
        directory: root,
        context: _context(),
      );

      // 已经拿到的 4 个字节不再重下。
      expect(resumed.ranges.first.$1, 4);
      expect(result.byteCount, 10);
      expect(
        File('${root.path}${Platform.pathSeparator}video.mp4')
            .readAsBytesSync(),
        _bytes(10),
      );
    });

    test('falls back to a whole-file response when Range is ignored', () async {
      final upstream = _RangeUpstream(
        {'https://cdn.test/full.flv': _bytes(9)},
        supportsRange: false,
      );
      final result = await AnimeFilePackageWriter(upstream, chunkSize: 4).write(
        track: const VideoTrack(url: 'https://cdn.test/full.flv'),
        headers: const {},
        directory: root,
        context: _context(),
      );

      expect(result.mediaName, 'video.flv');
      expect(result.byteCount, 9);
      expect(upstream.ranges, hasLength(1));
    });

    test('keeps origin credentials off cross-host resources', () async {
      final upstream = _RangeUpstream({
        'https://cdn.test/1080.m4s': _bytes(4),
        'https://other.test/audio.m4s': _bytes(4),
      });
      await AnimeFilePackageWriter(upstream).write(
        track: const VideoTrack(
          url: 'https://cdn.test/1080.m4s',
          audioUrl: 'https://other.test/audio.m4s',
        ),
        headers: const {
          'Authorization': 'Bearer origin-only',
          'Cookie': 'session=origin-only',
          'Referer': 'https://www.bilibili.com/',
        },
        directory: root,
        context: _context(),
      );

      final sent = upstream.sentHeaders['https://other.test/audio.m4s']!;
      expect(sent.containsKey('Authorization'), isFalse);
      expect(sent.containsKey('Cookie'), isFalse);
      expect(sent['Referer'], 'https://www.bilibili.com/');
    });
  });
}

AnimeDownloadStore _store(
  Directory root,
  HlsUpstreamClient upstream,
  List<VideoTrack> tracks,
) =>
    AnimeDownloadStore(
      rootProvider: () async => root.path,
      trackProvider: (_, __, ___) async => tracks,
      upstream: upstream,
    );

DownloadTask _task() => ContentDownloadTask.anime(
      sourceId: 'source',
      contentId: 'show',
      contentTitle: '测试番剧',
      chapterId: 'episode-1',
      chapterTitle: '第一集',
      now: 1,
    );

DownloadExecutionContext _context({DownloadCancellation? cancellation}) =>
    DownloadExecutionContext(
      cancellation: cancellation ?? DownloadCancellation(),
      reportProgress: (_, __) async {},
      checkpoint: () async {},
    );

List<int> _bytes(int length) =>
    List<int>.generate(length, (index) => index % 251);

List<int> _playlist() => '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-PLAYLIST-TYPE:VOD\n'
        '#EXTINF:4,\n'
        'one.ts\n'
        '#EXT-X-ENDLIST\n'
    .codeUnits;

class _RangeUpstream implements HlsUpstreamClient {
  _RangeUpstream(
    this.files, {
    this.supportsRange = true,
    this.cancelAfterChunks,
    this.cancellation,
  });

  final Map<String, List<int>> files;
  final bool supportsRange;

  /// 发出这么多块之后取消,模拟「下到一半被撤掉」。
  final int? cancelAfterChunks;
  final DownloadCancellation? cancellation;
  final List<(int, int)> ranges = [];
  final Map<String, Map<String, String>> sentHeaders = {};

  @override
  Future<HlsUpstreamResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    int? rangeStart,
    int? rangeLength,
  }) async {
    final key = uri.toString();
    sentHeaders[key] = Map<String, String>.of(headers);
    final body = files[key];
    if (body == null) {
      return const HlsUpstreamResponse(
          statusCode: 404, bytes: [], headers: {});
    }
    if (uri.path.endsWith('.m3u8') || uri.path.endsWith('.ts')) {
      return HlsUpstreamResponse(
          statusCode: 200, bytes: body, headers: const {});
    }
    ranges.add((rangeStart ?? 0, rangeLength ?? -1));
    if (cancelAfterChunks != null && ranges.length >= cancelAfterChunks!) {
      cancellation?.cancel();
    }
    if (!supportsRange || rangeStart == null || rangeLength == null) {
      return HlsUpstreamResponse(
          statusCode: 200, bytes: body, headers: const {});
    }
    if (rangeStart >= body.length) {
      return const HlsUpstreamResponse(
          statusCode: 416, bytes: [], headers: {});
    }
    final end =
        rangeStart + rangeLength > body.length ? body.length : rangeStart + rangeLength;
    return HlsUpstreamResponse(
      statusCode: 206,
      bytes: body.sublist(rangeStart, end),
      headers: {
        HttpHeaders.contentRangeHeader: [
          'bytes $rangeStart-${end - 1}/${body.length}',
        ],
      },
    );
  }
}
