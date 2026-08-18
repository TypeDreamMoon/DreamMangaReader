import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hls/hls.dart';

import 'support/fault_http_server.dart';

Future<
    ({
      int status,
      List<int> bytes,
      String text,
      String? contentRange,
    })> _get(
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
      contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
    );
  } finally {
    client.close(force: true);
  }
}

/// 等一个后台条件成立。预读是链式推进的,机器越忙推得越慢 —— 原来各处写死
/// 50×10ms(=500ms),在开发机上够、在 CI 上不够,超时后又**静默继续**,于是断言
/// 拿着半成品状态去比,报出来只是一句没头没脑的 "Expected: <1> Actual: <0>"。
///
/// 上限放到 5 秒:够吸收负载抖动,真坏掉时也不至于挂满整个测试超时。等不到就带着
/// [what] 直接失败,让错误信息自己说清楚等的是什么。
Future<void> _waitUntil(String what, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('等不到:$what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
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
      upstream: DioHlsUpstreamClient(Dio(),
          policy: const HlsUpstreamPolicy(allowLoopback: true)),
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

    // 缓冲还没起来:只预读紧邻的一片,别把带宽从正在播的那片手里抢走。
    await _waitUntil('预读 /360/001.ts',
        () => upstream.requestCount('/360/001.ts') == 1);
    expect(upstream.requestCount('/360/001.ts'), 1);
    expect(upstream.requestCount('/360/002.ts'), 0);
    expect(upstream.requestCount('/360/003.ts'), 0);
    // 预读过的那片直接走缓存,不会再回源第二遍。
    expect((await _get(media.segments[1].uri)).bytes, [1, 1, 1]);
    expect(upstream.requestCount('/360/001.ts'), 1);
    await _waitUntil('预读 /360/002.ts',
        () => upstream.requestCount('/360/002.ts') == 1);
    expect(upstream.requestCount('/360/002.ts'), 1);
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
    upstream.addBytes(
      '/media.mp4',
      [0, 1, 2, 3, 4, 5, 6, 7],
      honorRanges: false,
    );
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

  test('serves local ranges when an authenticated upstream ignores Range',
      () async {
    upstream.addText('/private.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
private.ts
#EXT-X-ENDLIST
''');
    upstream.addBytes(
      '/private.ts',
      [0, 1, 2, 3, 4],
      contentType: 'video/mp2t',
      honorRanges: false,
    );
    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('private.m3u8').toString(),
        hls: true,
        headers: const {'Authorization': 'Bearer fixture-token'},
      ),
      authScope: 'xiaojie_github',
    );
    final playlist = HlsParser.parse((await _get(session.localUri)).text)
        as HlsMediaPlaylist;

    final response = await _get(
      playlist.segments.single.uri,
      headers: const {HttpHeaders.rangeHeader: 'bytes=1-3'},
    );

    expect(response.status, HttpStatus.partialContent);
    expect(response.bytes, [1, 2, 3]);
    expect(response.contentRange, 'bytes 1-3/5');
    expect(
      upstream.requests.singleWhere((request) => request.path == '/private.ts'),
      isA<RecordedRequest>()
          .having((request) => request.range, 'range', 'bytes=1-3')
          .having(
            (request) => request.authorization,
            'authorization',
            'Bearer fixture-token',
          ),
    );
  });

  test('preserves multiple ordered maps as distinct local resources', () async {
    upstream.addText('/multi-map.m3u8', '''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="init-a.mp4"
#EXTINF:4,
a.m4s
#EXT-X-DISCONTINUITY
#EXT-X-MAP:URI="init-b.mp4"
#EXTINF:4,
b.m4s
#EXT-X-ENDLIST
''');
    upstream.addBytes('/init-a.mp4', [1, 1]);
    upstream.addBytes('/init-b.mp4', [2, 2]);
    upstream.addBytes('/a.m4s', [3]);
    upstream.addBytes('/b.m4s', [4]);
    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('multi-map.m3u8').toString(),
        hls: true,
      ),
      authScope: 'public',
    );

    final response = await _get(session.localUri);
    final mapMatches =
        RegExp(r'#EXT-X-MAP:URI="([^"]+)"').allMatches(response.text).toList();
    expect(mapMatches, hasLength(2));
    final firstMap = Uri.parse(mapMatches[0].group(1)!);
    final secondMap = Uri.parse(mapMatches[1].group(1)!);
    expect(firstMap, isNot(secondMap));
    expect(await _get(firstMap).then((value) => value.bytes), [1, 1]);
    expect(await _get(secondMap).then((value) => value.bytes), [2, 2]);
    expect(response.text.indexOf(firstMap.toString()),
        lessThan(response.text.indexOf('#EXT-X-DISCONTINUITY')));
    expect(response.text.indexOf(secondMap.toString()),
        greaterThan(response.text.indexOf('#EXT-X-DISCONTINUITY')));
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

  test('dio upstream exposes a chunk before the response completes', () async {
    final releaseTail = Completer<void>();
    addTearDown(() {
      if (!releaseTail.isCompleted) releaseTail.complete();
    });
    upstream.addChunked(
      '/direct-stream.ts',
      const [
        [1, 2],
        [3, 4],
      ],
      beforeChunk: (index) async {
        if (index == 1) await releaseTail.future;
      },
    );
    final response = await (DioHlsUpstreamClient(
      Dio(),
      policy: const HlsUpstreamPolicy(allowLoopback: true),
    ) as HlsStreamingUpstreamClient)
        .stream(
      upstream.baseUri.resolve('direct-stream.ts'),
      headers: const {},
    ).timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('upstream headers timed out'),
    );
    final first = Completer<List<int>>();
    final done = Completer<void>();
    response.stream.listen(
        (chunk) {
          if (!first.isCompleted) first.complete(List.of(chunk));
        },
        onDone: done.complete,
        onError: (Object error, StackTrace stackTrace) {
          if (!first.isCompleted) first.completeError(error, stackTrace);
          done.completeError(error, stackTrace);
        });
    expect(
      await first.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('direct first chunk timed out'),
      ),
      [1, 2],
    );
    releaseTail.complete();
    await done.future;
  });

  test('fault server flushes a raw HTTP chunk before completion', () async {
    final releaseTail = Completer<void>();
    addTearDown(() {
      if (!releaseTail.isCompleted) releaseTail.complete();
    });
    upstream.addChunked(
      '/raw-stream.ts',
      const [
        [1, 2],
        [3, 4],
      ],
      beforeChunk: (index) async {
        if (index == 1) await releaseTail.future;
      },
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(
      upstream.baseUri.resolve('raw-stream.ts'),
    ))
        .close();
    final first = Completer<List<int>>();
    final done = Completer<void>();
    response.listen((chunk) {
      if (!first.isCompleted) first.complete(List.of(chunk));
    }, onDone: done.complete, onError: done.completeError);
    expect(
      await first.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('raw first chunk timed out'),
      ),
      [1, 2],
    );
    releaseTail.complete();
    await done.future;
  });

  test('a foreground segment joins the in-flight prefetch instead of '
      'downloading it twice', () async {
    upstream.addText('/join.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
0.ts
#EXTINF:4,
1.ts
#EXTINF:4,
2.ts
#EXT-X-ENDLIST
''');
    upstream.addBytes('/0.ts', [0]);
    upstream.addBytes('/2.ts', [2]);
    final gate = Completer<void>();
    upstream.addChunked(
      '/1.ts',
      [
        [1],
        [1]
      ],
      beforeChunk: (index) async {
        if (index == 1) await gate.future; // 预读停在半路
      },
    );

    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('join.m3u8').toString(),
        hls: true,
      ),
      authScope: 'public',
    );
    final media = HlsParser.parse((await _get(session.localUri)).text)
        as HlsMediaPlaylist;
    await _get(media.segments.first.uri);
    await _waitUntil('预读 /1.ts', () => upstream.requestCount('/1.ts') == 1);
    expect(upstream.requestCount('/1.ts'), 1);

    // 播放器追上来要这一片:等预读落盘走缓存,而不是再开一路把同样的字节下第二遍。
    final second = _get(media.segments[1].uri);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    gate.complete();
    expect((await second).bytes, [1, 1]);
    expect(upstream.requestCount('/1.ts'), 1);
  });

  test('healthy buffer prefetches deeper but still stays bounded', () async {
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

    // 等的就是接下来要断言的三片都到齐,而不是只等最后一片。
    await _waitUntil(
        '预读 /1.ts /2.ts /3.ts',
        () =>
            upstream.requestCount('/1.ts') == 1 &&
            upstream.requestCount('/2.ts') == 1 &&
            upstream.requestCount('/3.ts') == 1);
    expect(upstream.requestCount('/1.ts'), 1);
    expect(upstream.requestCount('/2.ts'), 1);
    expect(upstream.requestCount('/3.ts'), 1);
    // 再往后就不读了:预读只是热身,不是把整集拖下来。
    expect(upstream.requestCount('/4.ts'), 0);
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

  test('streams first miss bytes before committing the cache', () async {
    final releaseTail = Completer<void>();
    addTearDown(() {
      if (!releaseTail.isCompleted) releaseTail.complete();
    });
    upstream.addText('/stream.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
slow.ts
#EXT-X-ENDLIST
''');
    upstream.addChunked(
      '/slow.ts',
      const [
        [1, 2],
        [3, 4],
      ],
      beforeChunk: (index) async {
        if (index == 1) await releaseTail.future;
      },
    );
    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('stream.m3u8').toString(),
        hls: true,
      ),
      authScope: 'public',
    );
    final media = HlsParser.parse((await _get(session.localUri)).text)
        as HlsMediaPlaylist;
    final client = HttpClient();
    final response =
        await (await client.getUrl(media.segments.single.uri)).close().timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw StateError('response headers timed out'),
            );
    final firstChunk = Completer<List<int>>();
    final all = <int>[];
    final done = Completer<void>();
    response.listen(
        (chunk) {
          all.addAll(chunk);
          if (!firstChunk.isCompleted) firstChunk.complete(List.of(chunk));
        },
        onDone: done.complete,
        onError: (Object error, StackTrace stackTrace) {
          if (!firstChunk.isCompleted) {
            firstChunk.completeError(error, stackTrace);
          }
          done.completeError(error, stackTrace);
        });

    expect(
      await firstChunk.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('first chunk timed out'),
      ),
      [1, 2],
    );
    expect(
      temp
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.bin')),
      isEmpty,
    );
    releaseTail.complete();
    await done.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('response completion timed out'),
    );
    expect(all, [1, 2, 3, 4]);
    expect((await _get(media.segments.single.uri)).bytes, [1, 2, 3, 4]);
    expect(upstream.requestCount('/slow.ts'), 1);
    client.close(force: true);
  });

  test('cache hits and upstream misses honor local byte ranges', () async {
    upstream.addText('/range.m3u8', '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
range.ts
#EXT-X-ENDLIST
''');
    upstream.addBytes('/range.ts', List<int>.generate(10, (index) => index));
    final session = await gateway.open(
      VideoTrack(
        url: upstream.baseUri.resolve('range.m3u8').toString(),
        hls: true,
      ),
      authScope: 'public',
    );
    final media = HlsParser.parse((await _get(session.localUri)).text)
        as HlsMediaPlaylist;
    final segment = media.segments.single.uri;

    final partialMiss = await _get(
      segment,
      headers: const {'Range': 'bytes=3-6'},
    );
    expect(partialMiss.status, HttpStatus.partialContent);
    expect(partialMiss.bytes, [3, 4, 5, 6]);
    expect(partialMiss.contentRange, 'bytes 3-6/10');
    expect(upstream.requests.last.range, 'bytes=3-6');

    expect(
        (await _get(segment)).bytes, List<int>.generate(10, (index) => index));
    final cachedRange = await _get(
      segment,
      headers: const {'Range': 'bytes=7-9'},
    );
    expect(cachedRange.status, HttpStatus.partialContent);
    expect(cachedRange.bytes, [7, 8, 9]);
    expect(cachedRange.contentRange, 'bytes 7-9/10');
    expect(upstream.requestCount('/range.ts'), 2);
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
