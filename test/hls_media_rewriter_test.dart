import 'package:dream_manga_reader/features/anime/playback/hls_media_rewriter.dart';
import 'package:flutter_test/flutter_test.dart';

HlsRewriteResult rewrite(String input) => HlsMediaRewriter().rewrite(
      input,
      baseUri: Uri.parse('https://media.example.test/video/'),
      register: (uri, kind, range) => Uri.parse(
        'http://127.0.0.1/${kind.name}/${uri.pathSegments.last}',
      ),
    );

void main() {
  test('binds map and implicit segment byte ranges to their registered URI',
      () {
    final registrations = <({Uri uri, HlsUriKind kind, HlsByteRange? range})>[];
    HlsMediaRewriter().rewrite(
      '''#EXTM3U
#EXT-X-MAP:URI="media.mp4",BYTERANGE="4@0"
#EXT-X-BYTERANGE:4@4
#EXTINF:4,
media.mp4
#EXT-X-BYTERANGE:4
#EXTINF:4,
media.mp4
#EXT-X-ENDLIST
''',
      baseUri: Uri.parse('https://media.example.test/video/'),
      register: (uri, kind, range) {
        registrations.add((uri: uri, kind: kind, range: range));
        return Uri.parse('http://127.0.0.1/${registrations.length}');
      },
    );

    expect(registrations, hasLength(3));
    expect(registrations[0].kind, HlsUriKind.init);
    expect(registrations[0].range?.length, 4);
    expect(registrations[0].range?.offset, 0);
    expect(registrations[1].range?.offset, 4);
    expect(registrations[2].range?.offset, 8);
  });

  test('preserves ordered maps keys ranges discontinuities and unknown tags',
      () {
    const input = '''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MAP:URI="init-a.mp4"
#EXT-X-KEY:METHOD=AES-128,URI="a.key"
#EXT-X-VENDOR-CUSTOM:keep-me
#EXTINF:4,
a.m4s
#EXT-X-DISCONTINUITY
#EXT-X-MAP:URI="init-b.mp4",BYTERANGE="10@20"
#EXT-X-BYTERANGE:10@30
#EXTINF:4,
b.m4s
#EXT-X-ENDLIST
''';

    final result = rewrite(input);

    expect(result.text.indexOf('/init/init-a.mp4'),
        lessThan(result.text.indexOf('/segment/a.m4s')));
    expect(result.text.indexOf('/init/init-b.mp4'),
        greaterThan(result.text.indexOf('#EXT-X-DISCONTINUITY')));
    expect(result.text, contains('#EXT-X-VENDOR-CUSTOM:keep-me'));
    expect(result.text, contains('#EXT-X-BYTERANGE:10@30'));
    expect(result.text, contains('/key/a.key'));
    expect(result.duration, const Duration(seconds: 8));
  });

  test('removes only a paired cue-out VOD range', () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
content-a.ts
#EXT-X-CUE-OUT:8
#EXTINF:4,
ad-a.ts
#EXTINF:4,
ad-b.ts
#EXT-X-CUE-IN
#EXTINF:4,
content-b.ts
#EXT-X-ENDLIST
''');

    expect(result.text, contains('content-a.ts'));
    expect(result.text, isNot(contains('ad-a.ts')));
    expect(result.text, isNot(contains('ad-b.ts')));
    expect(result.text, contains('content-b.ts'));
    expect(result.text, contains('#EXT-X-DISCONTINUITY'));
    expect(result.duration, const Duration(seconds: 8));
  });

  test('removes a timed explicit interstitial daterange from VOD', () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-DATERANGE:ID="ad-1",CLASS="com.apple.hls.interstitial",DURATION=8
#EXTINF:4,
ad-a.ts
#EXTINF:4,
ad-b.ts
#EXTINF:4,
content.ts
#EXT-X-ENDLIST
''');

    expect(result.text, isNot(contains('ad-a.ts')));
    expect(result.text, isNot(contains('ad-b.ts')));
    expect(result.text, contains('content.ts'));
    expect(result.duration, const Duration(seconds: 4));
  });

  test('bare discontinuity and ambiguous daterange preserve all content', () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-DISCONTINUITY
#EXT-X-DATERANGE:ID="chapter",CLASS="chapter"
#EXTINF:4,
keep.ts
#EXT-X-ENDLIST
''');

    expect(result.text, contains('#EXT-X-DISCONTINUITY'));
    expect(result.text, contains('#EXT-X-DATERANGE:ID="chapter"'));
    expect(result.text, contains('keep.ts'));
  });

  test('ad text inside an unrelated class name is not explicit advertising',
      () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-DATERANGE:ID="chapter",CLASS="shadow.timeline",DURATION=4
#EXTINF:4,
keep.ts
#EXT-X-ENDLIST
''');

    expect(result.text, contains('#EXT-X-DATERANGE:ID="chapter"'));
    expect(result.text, contains('keep.ts'));
    expect(result.duration, const Duration(seconds: 4));
  });

  test('playlist type VOD without endlist is still filtered as non-live', () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
content-a.ts
#EXT-X-CUE-OUT:4
#EXTINF:4,
ad.ts
#EXT-X-CUE-IN
#EXTINF:4,
content-b.ts
''');

    expect(result.isLive, isFalse);
    expect(result.text, isNot(contains('ad.ts')));
    expect(result.duration, const Duration(seconds: 8));
  });

  test('paired SCTE35 dateranges remove only their enclosed VOD segments', () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
content-a.ts
#EXT-X-DATERANGE:ID="splice-1",SCTE35-OUT=0xFC
#EXTINF:4,
ad.ts
#EXT-X-DATERANGE:ID="splice-1",SCTE35-IN=0xFC
#EXTINF:4,
content-b.ts
#EXT-X-ENDLIST
''');

    expect(result.text, contains('content-a.ts'));
    expect(result.text, isNot(contains('ad.ts')));
    expect(result.text, contains('content-b.ts'));
    expect(result.duration, const Duration(seconds: 8));
  });

  test('paired SCTE35 dateranges stay paired when OUT declares duration', () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
content-a.ts
#EXT-X-DATERANGE:ID="splice-2",SCTE35-OUT=0xFC,DURATION=4
#EXTINF:4,
ad.ts
#EXT-X-DATERANGE:ID="splice-2",SCTE35-IN=0xFC
#EXTINF:4,
content-b.ts
#EXT-X-ENDLIST
''');

    expect(result.text, contains('content-a.ts'));
    expect(result.text, isNot(contains('ad.ts')));
    expect(result.text, contains('content-b.ts'));
    expect(
      '#EXT-X-DISCONTINUITY'.allMatches(result.text),
      hasLength(1),
    );
    expect(result.duration, const Duration(seconds: 8));
  });

  test('live playlists never filter explicit cue markers', () {
    final result = rewrite('''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:20
#EXT-X-CUE-OUT:4
#EXTINF:4,
live-ad.ts
#EXT-X-CUE-IN
#EXTINF:4,
live-content.ts
''');

    expect(result.isLive, isTrue);
    expect(result.text, contains('live-ad.ts'));
    expect(result.text, contains('live-content.ts'));
    expect(result.text, contains('#EXT-X-CUE-OUT:4'));
  });

  test('an unpaired cue marker keeps the original segments', () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-CUE-OUT:4
#EXTINF:4,
keep-because-invalid.ts
#EXT-X-ENDLIST
''');

    expect(result.text, contains('keep-because-invalid.ts'));
    expect(result.text, contains('#EXT-X-CUE-OUT:4'));
  });
}
