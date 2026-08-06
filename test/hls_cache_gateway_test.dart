import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hls/hls.dart';

import 'support/fault_http_server.dart';

Future<({int status, List<int> bytes, String text})> _get(
  Uri uri, {
  Map<String, String>? headers,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    headers?.forEach(request.headers.set);
    final response = await request.close();
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
  late Directory temp;
  late FaultHttpServer upstream;
  late HlsCacheGateway gateway;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dmr-hls-gateway-test-');
    upstream = await FaultHttpServer.start();
    gateway = HlsCacheGateway(
      cache: HlsCacheStore(directory: temp, limitBytes: 1024 * 1024),
      upstream: DioHlsUpstreamClient(Dio(), policy: const HlsUpstreamPolicy(allowLoopback: true)),
      allowLoopbackUpstream: true,
    );
  });

  tearDown(() async {
    await gateway.close();
    await upstream.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('rewrites playlists, authenticates resources, prefetches and caches',
      () async {
    upstream.addText('/master.m3u8', '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360/index.m3u8
''');
    upstream.addText('/360/index.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
000.ts
#EXTINF:4,
001.ts
#EXTINF:4,
002.ts
#EXTINF:4,
003.ts
#EXT-X-ENDLIST
''');
    for (var index = 0; index < 4; index++) {
      upstream.addBytes('/360/00$index.ts', [index, index, index]);
    }
    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('master.m3u8').toString(),
        hls: true,
        headers: const {'Authorization': 'Bearer fixture-token'},
      ),
      authScope: 'xiaojie_github',
    );

    final masterResponse = await _get(session.localUri);
    expect(masterResponse.status, HttpStatus.ok);
    expect(masterResponse.text, contains(':${session.localUri.port}/'));
    expect(masterResponse.text, isNot(contains(':${upstream.baseUri.port}/')));
    final master = HlsParser.parse(masterResponse.text) as HlsMasterPlaylist;
    expect(
        master.variants.single.uri.host, InternetAddress.loopbackIPv4.address);

    final mediaResponse = await _get(master.variants.single.uri);
    final media = HlsParser.parse(mediaResponse.text) as HlsMediaPlaylist;
    expect(media.segments, hasLength(4));
    final first = await _get(media.segments.first.uri);
    expect(first.bytes, [0, 0, 0]);

    for (var attempt = 0; attempt < 50; attempt++) {
      if (upstream.requestCount('/360/003.ts') == 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(upstream.requestCount('/360/001.ts'), 1);
    expect(upstream.requestCount('/360/002.ts'), 1);
    expect(upstream.requestCount('/360/003.ts'), 1);
    await _get(media.segments[1].uri);
    expect(upstream.requestCount('/360/001.ts'), 1);
    expect(
      upstream.requests.every(
        (request) => request.authorization == 'Bearer fixture-token',
      ),
      isTrue,
    );

    await session.close();
    expect((await _get(session.localUri)).status, HttpStatus.notFound);
  });

  test('preserves map and byte ranges and keeps AES keys in session memory',
      () async {
    upstream.addText('/media.m3u8', '''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="media.mp4",BYTERANGE="4@0"
#EXT-X-KEY:METHOD=AES-128,URI="episode.key"
#EXTINF:4,
#EXT-X-BYTERANGE:4@4
media.mp4
#EXT-X-ENDLIST
''');
    upstream.addBytes('/media.mp4', [0, 1, 2, 3, 4, 5, 6, 7]);
    upstream.addBytes('/episode.key', List<int>.generate(16, (index) => index));
    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('media.m3u8').toString(),
        hls: true,
      ),
      authScope: 'private-fixture',
    );

    final playlist = HlsParser.parse((await _get(session.localUri)).text)
        as HlsMediaPlaylist;
    expect((await _get(playlist.initSegment!.uri)).bytes, [0, 1, 2, 3]);
    expect((await _get(playlist.segments.single.uri)).bytes, [4, 5, 6, 7]);
    final keyUri = playlist.segments.single.key!.uri!;
    expect(
        (await _get(keyUri)).bytes, List<int>.generate(16, (index) => index));
    await _get(keyUri);

    expect(upstream.requestCount('/episode.key'), 1);
    expect(
      upstream.requests
          .where((request) => request.path == '/media.mp4')
          .map((r) => r.range),
      containsAll(['bytes=0-3', 'bytes=4-7']),
    );
  });

  test('retries one upstream 500 before succeeding', () async {
    upstream.addText(
      '/retry.m3u8',
      '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n0.ts\n#EXT-X-ENDLIST\n',
      failuresBeforeSuccess: 1,
    );
    upstream.addBytes('/0.ts', [7]);
    final session = await gateway.open(
      VideoTrack(
          url: upstream.baseUri.resolve('retry.m3u8').toString(), hls: true),
      authScope: 'public',
    );

    expect((await _get(session.localUri)).status, HttpStatus.ok);
    expect(upstream.requestCount('/retry.m3u8'), 2);
  });

  test('healthy buffer allows exactly one extra forward prefetch', () async {
    upstream.addText('/forward.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
0.ts
#EXTINF:4,
1.ts
#EXTINF:4,
2.ts
#EXTINF:4,
3.ts
#EXTINF:4,
4.ts
#EXT-X-ENDLIST
''');
    for (var index = 0; index < 5; index++) {
      upstream.addBytes('/$index.ts', [index]);
    }
    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('forward.m3u8').toString(),
        hls: true,
      ),
      authScope: 'public',
    );
    session.reportBuffer(const Duration(seconds: 20));
    final media = HlsParser.parse((await _get(session.localUri)).text)
        as HlsMediaPlaylist;
    await _get(media.segments.first.uri);

    for (var attempt = 0; attempt < 50; attempt++) {
      if (upstream.requestCount('/4.ts') == 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(upstream.requestCount('/1.ts'), 1);
    expect(upstream.requestCount('/2.ts'), 1);
    expect(upstream.requestCount('/3.ts'), 1);
    expect(upstream.requestCount('/4.ts'), 1);
    session.notifySeek();
  });

  test('live playlists bypass disk cache and forward prefetch', () async {
    upstream.addText('/live.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:10
#EXTINF:4,
10.ts
#EXTINF:4,
11.ts
''');
    upstream.addBytes('/10.ts', [10]);
    upstream.addBytes('/11.ts', [11]);
    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('live.m3u8').toString(),
        hls: true,
      ),
      authScope: 'public',
    );
    final media = HlsParser.parse((await _get(session.localUri)).text)
        as HlsMediaPlaylist;

    await _get(media.segments.first.uri);
    await _get(media.segments.first.uri);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(upstream.requestCount('/10.ts'), 2);
    expect(upstream.requestCount('/11.ts'), 0);
  });

  test('rejects unsupported encryption instead of pretending it is cached',
      () async {
    upstream.addText('/drm.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="drm.key",KEYFORMAT="com.example.drm"
#EXTINF:4,
0.m4s
#EXT-X-ENDLIST
''');
    final session = await gateway.open(
      VideoTrack(
          url: upstream.baseUri.resolve('drm.m3u8').toString(), hls: true),
      authScope: 'public',
    );

    final response = await _get(session.localUri);
    expect(response.status, HttpStatus.notImplemented);
    expect(response.text, contains('unsupported-hls-encryption'));
  });

  test('withholds credential headers from cross-host playlist resources',
      () async {
    // 清单由上游控制,可以把分片指向任意主机。原站的 Authorization 只能回源到原主机,
    // 否则一个被改写的清单就能把用户凭据递给第三方。
    // localhost 与 127.0.0.1 指向同一台机器但 host 串不同,正好用来模拟换主机。
    final foreign = 'http://localhost:${upstream.baseUri.port}';
    upstream.addText('/index.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
same.ts
#EXTINF:4,
$foreign/foreign.ts
#EXT-X-ENDLIST
''');
    upstream.addBytes('/same.ts', const [1]);
    upstream.addBytes('/foreign.ts', const [2]);

    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('index.m3u8').toString(),
        hls: true,
        headers: const {
          'Authorization': 'Bearer origin-only',
          'Referer': 'https://origin.example.com/',
        },
      ),
      authScope: 'xiaojie_github',
    );

    final mediaResponse = await _get(session.localUri);
    final media = HlsParser.parse(mediaResponse.text) as HlsMediaPlaylist;
    expect(media.segments, hasLength(2));

    await _get(media.segments[0].uri);
    await _get(media.segments[1].uri);

    final same = upstream.requests.lastWhere((r) => r.path == '/same.ts');
    final cross = upstream.requests.lastWhere((r) => r.path == '/foreign.ts');
    expect(same.authorization, 'Bearer origin-only');
    expect(cross.authorization, isNull);
  });
}
