import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_store.dart';
import 'package:dream_manga_reader/features/anime/playback/media_kit_player_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hls/hls.dart';

import 'support/fault_http_server.dart';

class _IntegrationBackend implements MediaKitBackend {
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);
  final bufferController = StreamController<Duration>.broadcast(sync: true);
  final opened = <VideoTrack>[];
  final seeks = <Duration>[];
  int clearedAudioCount = 0;

  @override
  Stream<bool> get playing => playingController.stream;
  @override
  Stream<bool> get buffering => bufferingController.stream;
  @override
  Stream<Duration> get position => positionController.stream;
  @override
  Stream<Duration> get durationChanges => const Stream.empty();
  @override
  Stream<bool> get completed => completedController.stream;
  @override
  Stream<Object> get errors => errorController.stream;
  @override
  Stream<Duration> get buffer => bufferController.stream;
  @override
  Duration get duration => const Duration(minutes: 24);
  @override
  Future<void> configure(VideoTrack track) async {}
  @override
  Future<void> open(VideoTrack track) async => opened.add(track);
  @override
  Future<void> attachAudio(String url) async {}
  @override
  Future<void> clearAudio() async => clearedAudioCount++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> dispose() async {}
}

/// 等一个异步链跑完。断言前只推一轮微任务在多 await 的路径上会随机抢跑。
Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('等待条件超时');
}

Future<({int status, List<int> bytes, String text})> _get(Uri uri) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(uri)).close();
    final bytes =
        await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    return (
      status: response.statusCode,
      bytes: bytes,
      text: utf8.decode(bytes, allowMalformed: true),
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('private HLS caches, resumes direct fallback and never persists token',
      () async {
    const sentinel = 'DO_NOT_PERSIST_BEARER_6f81';
    final directory =
        await Directory.systemTemp.createTemp('dmr-player-integration-');
    final upstream = await FaultHttpServer.start();
    final store = HlsCacheStore(
      directory: directory,
      limitBytes: 1024 * 1024,
    );
    final gateway = HlsCacheGateway(
      cache: store,
      upstream: DioHlsUpstreamClient(Dio(), policy: const HlsUpstreamPolicy(allowLoopback: true)),
      allowLoopbackUpstream: true,
    );
    final backend = _IntegrationBackend();
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: gateway,
      authScope: 'source:xiaojie-anime',
    );
    addTearDown(() async {
      await adapter.dispose();
      await gateway.close();
      await upstream.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    upstream.addText('/episode.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="init-a.mp4"
#EXTINF:4,
0.ts
#EXT-X-CUE-OUT:4
#EXTINF:4,
ad.ts
#EXT-X-CUE-IN
#EXT-X-DISCONTINUITY
#EXT-X-MAP:URI="init-b.mp4"
#EXTINF:4,
1.ts
#EXT-X-ENDLIST
''');
    upstream.addBytes('/init-a.mp4', [1, 1]);
    upstream.addBytes('/init-b.mp4', [2, 2]);
    upstream.addBytes('/0.ts', [7, 8, 9], contentType: 'video/mp2t');
    upstream.addBytes('/ad.ts', [99], contentType: 'video/mp2t');
    upstream.addBytes('/1.ts', [10, 11], contentType: 'video/mp2t');
    final track = VideoTrack(
      url: upstream.baseUri.resolve('episode.m3u8').toString(),
      quality: '480p',
      hls: true,
      headers: const {'Authorization': 'Bearer $sentinel'},
    );

    await adapter.open(track);
    final local = Uri.parse(backend.opened.single.url);
    expect(InternetAddress.tryParse(local.host)?.isLoopback, isTrue);
    expect(backend.opened.single.headers, isNull);
    final rewritten = (await _get(local)).text;
    expect(rewritten, isNot(contains('ad.ts')));
    expect(
        RegExp(r'#EXT-X-MAP:URI="[^"]+"').allMatches(rewritten), hasLength(2));
    final playlist = HlsParser.parse(rewritten) as HlsMediaPlaylist;
    expect(playlist.segments, hasLength(2));
    expect((await _get(playlist.segments.first.uri)).bytes, [7, 8, 9]);
    expect((await _get(playlist.segments.last.uri)).bytes, [10, 11]);
    await _get(playlist.segments.first.uri);
    expect(upstream.requestCount('/0.ts'), 1);
    expect(upstream.requestCount('/ad.ts'), 0);
    expect(
      upstream.requests.every(
        (request) => request.authorization == 'Bearer $sentinel',
      ),
      isTrue,
    );

    await adapter.seek(const Duration(seconds: 42));
    backend.positionController.add(Duration.zero);
    backend.errorController.add(StateError('HTTP 501 gateway fallback'));
    // 回退到直连要串起 clearAudio → 关会话 → configure → open 好几个 await,
    // 单个 Duration.zero 只推进一轮微任务,推不完整条链(约 1/5 概率抢跑)。
    await _waitFor(() => backend.opened.length > 1);
    expect(backend.opened.last.url, track.url);
    expect(backend.seeks.last, const Duration(seconds: 42));
    expect(backend.clearedAudioCount, 1);

    // 索引是后台合并写的:先等它落盘,再读文件(否则读到的是正在被改写的那一刻)。
    await store.flushIndex();
    final persisted = <String>[
      ...directory.listSync().map((entry) => entry.path),
      if (File('${directory.path}${Platform.pathSeparator}index.json')
          .existsSync())
        File('${directory.path}${Platform.pathSeparator}index.json')
            .readAsStringSync(),
    ].join('\n');
    expect(persisted, isNot(contains(sentinel)));
  });
}
