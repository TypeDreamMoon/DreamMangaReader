import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/local/local_track_provider.dart';

void main() {
  const track = VideoTrack(url: 'file:///F:/media/Show.S01E02.mkv', quality: '本地');

  group('LocalTrackProvider', () {
    test('refresh 返回当前 track', () async {
      final provider = LocalTrackProvider(track);
      expect(await provider.refresh(), [track]);
    });

    test('refresh 永不返回空列表 —— 空列表会让恢复阶梯直接落到 failed', () async {
      final provider = LocalTrackProvider(track);
      for (var attempt = 0; attempt < 3; attempt++) {
        expect(await provider.refresh(), isNotEmpty);
      }
    });

    test('换掉 track 之后 refresh 给新的那条', () async {
      final provider = LocalTrackProvider(track);
      const updated = VideoTrack(
        url: 'file:///F:/media/Show.S01E02.mkv',
        quality: '本地',
        subtitles: [SubtitleAsset(url: 'file:///F:/media/Show.S01E02.zh.srt')],
      );
      provider.track = updated;
      expect(provider.track, updated);
      expect(await provider.refresh(), [updated]);
    });

    test('matchRefreshed 取首条;空列表返回 null', () {
      final provider = LocalTrackProvider(track);
      expect(provider.matchRefreshed(track, [track]), same(track));
      const other = VideoTrack(url: 'file:///F:/media/Other.mkv');
      expect(provider.matchRefreshed(track, [other]), same(other));
      expect(provider.matchRefreshed(track, const []), isNull);
    });

    test('lowerQuality / alternateLine 恒 null(本地没有清晰度与线路)', () {
      final provider = LocalTrackProvider(track);
      expect(provider.lowerQuality(track, [track]), isNull);
      expect(provider.alternateLine(track, [track]), isNull);
    });
  });
}
