import 'dart:io';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/track_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

const _headers = {'Authorization': 'Bearer fixture-token'};

void main() {
  // 播放页自带的取清单通道背后是一条 HttpClient 连接池。原来它跟着播放页一起
  // 被丢掉却从没关过 —— 看一晚上番就攒下几十条闲着的连接。
  test('the playlist client closes its own connection pool', () async {
    final client = DioPlaylistClient();
    expect(client.isClosed, isFalse);

    client.close();
    expect(client.isClosed, isTrue);
    // 关过之后再取就该炸:证明底下那条池子真的关了,不是只翻了个标志位。
    await expectLater(
      client.fetch(Uri.parse('https://media.example.test/master.m3u8'), const {}),
      throwsA(anything),
    );

    client.close(); // 幂等,dispose 跑两遍也不该出事
    expect(client.isClosed, isTrue);
  });

  test('resolves master variants with declared metadata and headers', () async {
    final resolver = TrackResolver(
      fetchPlaylist: (uri, headers) async {
        expect(uri.toString(), 'https://media.example.test/root/master.m3u8');
        expect(headers, _headers);
        return File('test/fixtures/hls/master.m3u8').readAsStringSync();
      },
      refreshTracks: () async => const [],
    );

    final tracks = await resolver.resolve(const [
      VideoTrack(
        url: 'https://media.example.test/root/master.m3u8',
        quality: '自动',
        hls: true,
        headers: _headers,
      ),
    ]);

    expect(tracks.map((track) => track.quality), ['480P', '360P']);
    expect(
      tracks.map((track) => track.url),
      [
        'https://media.example.test/root/480p/index.m3u8',
        'https://media.example.test/root/360p/index.m3u8',
      ],
    );
    expect(tracks.every((track) => track.headers == _headers), isTrue);
    expect(resolver.bandwidthOf(tracks.first), 1400000);
    expect(resolver.resolutionOf(tracks.first), (width: 854, height: 480));
  });

  test('letterboxed and 4:3 variants land in the tier viewers recognise',
      () async {
    final resolver = TrackResolver(
      fetchPlaylist: (_, __) async =>
          File('test/fixtures/hls/master_widescreen.m3u8').readAsStringSync(),
      refreshTracks: () async => const [],
    );

    final tracks = await resolver.resolve(const [
      VideoTrack(
        url: 'https://media.example.test/root/master.m3u8',
        hls: true,
      ),
    ]);

    // 1920×608 是 2.35:1 的宽银幕番剧,行数确实只有 608,但没人管它叫 608p;
    // 1440×1080 是 4:3,按宽归档会掉成 720P。两条都该落在 1080P。
    // 三条撞在同一档,所以每条都补上真实分辨率 —— 否则面板上三行长得一样。
    expect(tracks.map((track) => track.quality), [
      '1080P · 1920×608',
      '1080P · 1920×1080',
      '1080P · 1440×1080',
    ]);
  });

  test('keeps explicit source tracks without fetching or guessing bitrate',
      () async {
    var fetches = 0;
    final resolver = TrackResolver(
      fetchPlaylist: (_, __) async {
        fetches++;
        return '';
      },
      refreshTracks: () async => const [],
    );
    const sourceTracks = [
      VideoTrack(url: 'https://a.example.test/video', quality: '高清'),
      VideoTrack(url: 'https://b.example.test/video', quality: '流畅'),
    ];

    final resolved = await resolver.resolve(sourceTracks);

    expect(resolved, sourceTracks);
    expect(fetches, 0);
    expect(resolver.bandwidthOf(resolved.first), isNull);
    expect(resolver.lowerQuality(resolved.first, resolved), isNull);
  });

  test('rejects unsafe master and variant URLs', () async {
    Future<void> rejects(String masterUrl, String body) async {
      final resolver = TrackResolver(
        fetchPlaylist: (_, __) async => body,
        refreshTracks: () async => const [],
      );
      await expectLater(
        resolver.resolve([VideoTrack(url: masterUrl, hls: true)]),
        throwsFormatException,
      );
    }

    await rejects('file:///tmp/master.m3u8', '#EXTM3U');
    await rejects(
      'https://media.example.test/master.m3u8',
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nfile:///etc/passwd\n',
    );
    await rejects(
      'https://media.example.test/master.m3u8',
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttp://127.0.0.1/private\n',
    );
    await rejects(
      'https://user:password@media.example.test/master.m3u8',
      '#EXTM3U',
    );
  });

  test('refresh matches quality and alternate line without crossing quality',
      () async {
    const refreshed = [
      VideoTrack(url: 'https://new.example.test/480.m3u8', quality: '480p'),
      VideoTrack(url: 'https://alt.example.test/480.m3u8', quality: '480p'),
      VideoTrack(url: 'https://new.example.test/360.m3u8', quality: '360p'),
    ];
    final resolver = TrackResolver(
      fetchPlaylist: (_, __) async => '',
      refreshTracks: () async => refreshed,
    );
    const current =
        VideoTrack(url: 'https://old.example.test/480.m3u8', quality: '480p');

    final loaded = await resolver.refresh();
    final match = resolver.matchRefreshed(current, loaded)!;

    expect(match.url, 'https://new.example.test/480.m3u8');
    expect(
      resolver.alternateLine(match, loaded)?.url,
      'https://alt.example.test/480.m3u8',
    );
  });
}
