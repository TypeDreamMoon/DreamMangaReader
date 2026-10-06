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
    // 范围已经绑进本地 URI(网关按注册时的 range 回源),清单里不能再留一份,
    // 否则播放器会对着「已经切好的那一段」二次取偏移 —— 偏移叠加两次直接 416。
    expect(result.text, isNot(contains('#EXT-X-BYTERANGE')));
    expect(result.text, isNot(contains('BYTERANGE=')));
    expect(result.text, contains('#EXT-X-MAP:URI="http://127.0.0.1/init/init-b.mp4"'));
    expect(result.text, contains('/key/a.key'));
    expect(result.duration, const Duration(seconds: 8));
  });

  // AES-128 不带 IV= 时,IV 就是分片的媒体序号。删掉中间的广告片会让留下来的分片
  // 在输出里往前挪 —— 序号变了,隐式 IV 就错了,播放器解出来是一堆花屏。
  test('pins an explicit IV on segments kept after an ad break', () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MEDIA-SEQUENCE:10
#EXT-X-KEY:METHOD=AES-128,URI="a.key"
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
#EXTINF:4,
content-c.ts
#EXT-X-ENDLIST
''');

    expect(result.text, contains('/segment/content-b.ts'));
    expect(result.text, isNot(contains('/segment/ad-a.ts')));
    // 广告之前那片没挪位置,不该被补 IV。
    final lines = result.text.split('\n');
    final firstKey =
        lines.indexWhere((line) => line.startsWith('#EXT-X-KEY:'));
    expect(lines[firstKey], isNot(contains('IV=')));
    // content-b 原本是第 13 片(10 + 3),content-c 是第 14 片。
    expect(
      result.text,
      contains('#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1/key/a.key",'
          'IV=0x0000000000000000000000000000000d'),
    );
    expect(
      result.text,
      contains('#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1/key/a.key",'
          'IV=0x0000000000000000000000000000000e'),
    );
    // 序号本身照旧透传:显式 IV 已经把偏移问题接管了。
    expect(result.text, contains('#EXT-X-MEDIA-SEQUENCE:10'));
  });

  test('leaves an explicit IV and an unfiltered playlist untouched', () {
    final result = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MEDIA-SEQUENCE:10
#EXT-X-KEY:METHOD=AES-128,URI="a.key",IV=0x00000000000000000000000000000001
#EXTINF:4,
content-a.ts
#EXT-X-CUE-OUT:4
#EXTINF:4,
ad-a.ts
#EXT-X-CUE-IN
#EXTINF:4,
content-b.ts
#EXT-X-ENDLIST
''');

    // 上游自己给了 IV,序号错位跟它无关 —— 一行都不该多。
    expect(
      '#EXT-X-KEY:'.allMatches(result.text),
      hasLength(1),
    );
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
