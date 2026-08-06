import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hls/hls.dart';

String _fixture(String name) =>
    File('test/fixtures/hls/$name').readAsStringSync();

HlsPlaylist _roundTrip(String name) {
  final parsed = HlsParser.parse(
    _fixture(name),
    baseUri: Uri.parse('https://media.example.test/root/'),
  );
  final normalized = HlsComposer.normalize(parsed);
  return HlsParser.parse(HlsComposer.compose(normalized));
}

void main() {
  test('master playlist preserves variants and quality metadata', () {
    final playlist = _roundTrip('master.m3u8') as HlsMasterPlaylist;

    expect(playlist.variants, hasLength(2));
    expect(
      playlist.variants.map((variant) => variant.uri.toString()),
      [
        'https://media.example.test/root/480p/index.m3u8',
        'https://media.example.test/root/360p/index.m3u8',
      ],
    );
    expect(playlist.variants.first.bandwidth, 1800000);
    expect(playlist.variants.first.averageBandwidth, 1400000);
    expect(playlist.variants.first.width, 854);
    expect(playlist.variants.first.height, 480);
  });

  test('TS playlist preserves AES-128 key and VOD ending', () {
    final playlist = _roundTrip('media-ts.m3u8') as HlsMediaPlaylist;

    expect(playlist.hasEndTag, isTrue);
    expect(playlist.isLive, isFalse);
    expect(playlist.segments, hasLength(2));
    expect(playlist.segments.first.key?.method, 'AES-128');
    expect(
      playlist.segments.first.key?.uri.toString(),
      'https://media.example.test/root/keys/episode.key',
    );
  });

  test('fMP4 playlist preserves map and byte ranges', () {
    final playlist = _roundTrip('media-fmp4.m3u8') as HlsMediaPlaylist;

    expect(
      playlist.initSegment?.uri.toString(),
      'https://media.example.test/root/media.mp4',
    );
    expect(playlist.initSegment?.byteRange?.length, 720);
    expect(playlist.initSegment?.byteRange?.offset, 0);
    expect(playlist.segments.first.byteRange?.length, 2800);
    expect(playlist.segments.first.byteRange?.offset, 720);
    expect(playlist.segments.last.byteRange?.length, 1900);
    expect(playlist.segments.last.byteRange?.offset, 3520);
  });
}
