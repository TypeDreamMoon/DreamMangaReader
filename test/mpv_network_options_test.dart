import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/mpv_network_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const track = VideoTrack(url: 'https://media.example.test/video.m3u8');

  test('keeps media_kit demuxer retries without a proxy', () {
    final options = MpvNetworkOptions.forTrack(track);

    expect(options.networkTimeoutSeconds, 60);
    expect(options.httpProxy, isNull);
    expect(options.demuxerLavf, contains('seg_max_retry=5'));
    expect(options.demuxerLavf, contains('strict=experimental'));
    expect(options.demuxerLavf, contains('allowed_extensions=ALL'));
    expect(
      options.demuxerLavf,
      contains(
        'protocol_whitelist=[file,crypto,data,http,https,tcp,tls,'
        'httpproxy,hls,applehttp]',
      ),
    );
  });

  test('adds an HTTP proxy without replacing demuxer retries', () {
    final options = MpvNetworkOptions.forTrack(
      track,
      proxy: ' 127.0.0.1:7897 ',
    );

    expect(options.httpProxy, 'http://127.0.0.1:7897');
    expect(options.streamLavf, contains('httpproxy'));
    expect(options.demuxerLavf, contains('seg_max_retry=5'));
  });

  test('uses a source supplied user agent case-insensitively', () {
    const custom = VideoTrack(
      url: 'https://media.example.test/video.mp4',
      headers: {'user-agent': 'Fixture Player/1.0'},
    );

    final options = MpvNetworkOptions.forTrack(custom);

    expect(options.userAgent, 'Fixture Player/1.0');
  });

  test('rejects proxy strings that already contain a URL path', () {
    expect(
      () => MpvNetworkOptions.forTrack(
        track,
        proxy: 'http://127.0.0.1:7897/path',
      ),
      throwsFormatException,
    );
  });
}
