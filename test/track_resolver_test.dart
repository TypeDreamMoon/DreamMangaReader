import 'dart:io';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/track_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

const _headers = {'Authorization': 'Bearer fixture-token'};

void main() {
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

    expect(tracks.map((track) => track.quality), ['480p', '360p']);
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
