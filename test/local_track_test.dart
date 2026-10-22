import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:dream_manga_reader/features/local/local_track.dart';

void main() {
  LocalMediaItem item({
    String location = r'F:\media\Show\Show.S01E02.1080p.mkv',
    List<LocalSubtitle> subtitles = const [],
  }) =>
      LocalMediaItem(
        id: 'item-1',
        libraryId: 'lib-1',
        title: 'Show S01E02',
        location: location,
        season: 1,
        episode: 2,
        subtitles: subtitles,
      );

  group('buildLocalTrack', () {
    test('Windows 绝对路径产出 file: URL(hls 恒 false、headers 恒 null)', () {
      final track = buildLocalTrack(
        item(),
        qualityLabel: '本地',
        windows: true,
      );

      expect(track.url, 'file:///F:/media/Show/Show.S01E02.1080p.mkv');
      expect(track.hls, isFalse);
      expect(track.headers, isNull);
      expect(track.audioUrl, isNull);
      expect(track.quality, '本地');
      expect(track.subtitles, isEmpty);
    });

    test('POSIX 路径(路线 B 导入后的真实路径)同样产出 file: URL', () {
      final track = buildLocalTrack(
        item(location: '/data/user/0/app/files/local-import/x/E01.mkv'),
        qualityLabel: '本地',
        windows: false,
      );

      expect(track.url, 'file:///data/user/0/app/files/local-import/x/E01.mkv');
      expect(track.hls, isFalse);
    });

    test('Android 的 fd:// 描述符地址原样透传,不再包 file://', () {
      // /proc/self/fd/N 在 Android 10+ 上会被内核按真实路径再查一次权限 → EACCES;
      // mpv 的 fd 协议直接 dup 描述符读写,所以生产用 fd://(见 OpenedLocalFd.playUrl)。
      final track = buildLocalTrack(
        item(location: 'fd://42'),
        qualityLabel: '本地',
        windows: false,
      );

      expect(track.url, 'fd://42');
      expect(track.hls, isFalse);
      expect(track.headers, isNull);
    });

    test('fd:// 的字幕地址同样原样透传', () {
      final track = buildLocalTrack(
        item(
          location: 'fd://42',
          subtitles: const [
            LocalSubtitle(location: 'fd://43', label: '简体中文', language: 'zh'),
          ],
        ),
        qualityLabel: '本地',
        windows: false,
      );

      expect(track.subtitles.single.url, 'fd://43');
    });

    test('路径可经 Uri 还原(不手工拼字符串)', () {
      const location = r'F:\media\Show\Show.S01E02.1080p.mkv';
      final track = buildLocalTrack(
        item(),
        qualityLabel: '本地',
        windows: true,
      );

      expect(Uri.parse(track.url).toFilePath(windows: true), location);
    });

    test('条目自带的字幕被映射成 SubtitleAsset', () {
      final track = buildLocalTrack(
        item(
          subtitles: const [
            LocalSubtitle(
              location: r'F:\media\Show\Show.S01E02.zh.srt',
              label: '简体中文',
              language: 'zh',
            ),
          ],
        ),
        qualityLabel: '本地',
        windows: true,
      );

      expect(track.subtitles, hasLength(1));
      expect(
        track.subtitles.single.url,
        'file:///F:/media/Show/Show.S01E02.zh.srt',
      );
      expect(track.subtitles.single.label, '简体中文');
      expect(track.subtitles.single.language, 'zh');
    });

    test('显式传入的字幕列表覆盖条目自带的字幕', () {
      final track = buildLocalTrack(
        item(
          subtitles: const [
            LocalSubtitle(location: r'F:\media\a.srt', label: 'a'),
          ],
        ),
        subtitles: const [LocalSubtitle(location: '/mnt/b.ass', label: 'b')],
        qualityLabel: '本地',
        windows: false,
      );

      expect(track.subtitles, hasLength(1));
      expect(track.subtitles.single.url, 'file:///mnt/b.ass');
      expect(track.subtitles.single.label, 'b');
    });

    test('location 为空的字幕条目被跳过', () {
      final track = buildLocalTrack(
        item(
          subtitles: const [
            LocalSubtitle(location: '   ', label: 'empty'),
            LocalSubtitle(location: '/mnt/ok.srt', label: 'ok'),
          ],
        ),
        qualityLabel: '本地',
        windows: false,
      );

      expect(track.subtitles, hasLength(1));
      expect(track.subtitles.single.label, 'ok');
    });

    test('content:// URI 直接被拒绝(必须经桥换成可播路径)', () {
      expect(
        () => buildLocalTrack(
          item(location: 'content://com.android.providers.media.documents/1'),
          qualityLabel: '本地',
          windows: false,
        ),
        throwsArgumentError,
      );
    });

    test('空 location 被拒绝', () {
      expect(
        () => buildLocalTrack(item(location: '  '), qualityLabel: '本地'),
        throwsArgumentError,
      );
    });
  });
}
