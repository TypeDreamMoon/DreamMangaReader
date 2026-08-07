import 'package:dream_manga_reader/core/novel/reader/novel_reader_theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ships white, eye-care, dark, black and paper profiles', () {
    expect(NovelReaderTheme.values, [
      NovelReaderTheme.white,
      NovelReaderTheme.eyeCare,
      NovelReaderTheme.dark,
      NovelReaderTheme.black,
      NovelReaderTheme.paper,
    ]);

    for (final theme in NovelReaderTheme.values) {
      final profile = novelReaderThemeProfile(theme);
      expect(
        colorContrastRatio(profile.backgroundArgb, profile.foregroundArgb),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        colorContrastRatio(profile.chromeArgb, profile.chromeForegroundArgb),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        colorContrastRatio(
          profile.systemBarArgb,
          profile.systemBarForegroundArgb,
        ),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('custom foreground overrides automatic readable foreground', () {
    final automatic = novelReaderThemeProfile(NovelReaderTheme.paper);
    final custom = novelReaderThemeProfile(
      NovelReaderTheme.paper,
      foregroundOverrideArgb: 0xff314159,
    );

    expect(custom.backgroundArgb, automatic.backgroundArgb);
    expect(custom.foregroundArgb, 0xff314159);
  });

  test('background CSS supports crop, tile and fill without gradients', () {
    final uri = Uri.file(r'D:\reader backgrounds\paper.png');

    final crop = buildNovelBackgroundCss(
      uri: uri,
      fit: NovelBackgroundFit.crop,
      strength: .6,
    );
    final tile = buildNovelBackgroundCss(
      uri: uri,
      fit: NovelBackgroundFit.tile,
      strength: .4,
    );
    final fill = buildNovelBackgroundCss(
      uri: uri,
      fit: NovelBackgroundFit.fill,
      strength: 1,
    );

    expect(crop, contains('background-size:cover'));
    expect(tile, contains('background-repeat:repeat'));
    expect(fill, contains('background-size:100% 100%'));
    expect(crop, contains('opacity:0.6'));
    expect('$crop$tile$fill', isNot(contains('gradient')));
  });
}
