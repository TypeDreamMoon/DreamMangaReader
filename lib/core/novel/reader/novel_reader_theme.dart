import 'dart:math' as math;

enum NovelReaderTheme { white, eyeCare, dark, black, paper }

enum NovelBackgroundFit { crop, tile, fill }

class NovelReaderThemeProfile {
  const NovelReaderThemeProfile({
    required this.theme,
    required this.backgroundArgb,
    required this.foregroundArgb,
    required this.chromeArgb,
    required this.chromeForegroundArgb,
    required this.systemBarArgb,
    required this.systemBarForegroundArgb,
  });

  final NovelReaderTheme theme;
  final int backgroundArgb;
  final int foregroundArgb;
  final int chromeArgb;
  final int chromeForegroundArgb;
  final int systemBarArgb;
  final int systemBarForegroundArgb;
}

NovelReaderThemeProfile novelReaderThemeProfile(
  NovelReaderTheme theme, {
  int? foregroundOverrideArgb,
  int? readabilityBackgroundArgb,
}) {
  final background = switch (theme) {
    NovelReaderTheme.white => 0xffffffff,
    NovelReaderTheme.eyeCare => 0xffdfe8cf,
    NovelReaderTheme.dark => 0xff1d2023,
    NovelReaderTheme.black => 0xff000000,
    NovelReaderTheme.paper => 0xffeee5d1,
  };
  final automaticForeground =
      _relativeLuminance(readabilityBackgroundArgb ?? background) > .45
          ? 0xff202124
          : 0xffeeeeee;
  final foreground = foregroundOverrideArgb ?? automaticForeground;
  final dark = _relativeLuminance(background) < .35;
  return NovelReaderThemeProfile(
    theme: theme,
    backgroundArgb: background,
    foregroundArgb: foreground,
    chromeArgb: dark ? 0xe61c1e20 : 0xe6ffffff,
    chromeForegroundArgb: dark ? 0xffeeeeee : 0xff202124,
    systemBarArgb: dark ? 0xff111214 : 0xfff7f5ef,
    systemBarForegroundArgb: dark ? 0xffeeeeee : 0xff202124,
  );
}

int blendNovelReaderArgb(int baseArgb, int overlayArgb, double amount) {
  final bounded = amount.isFinite ? amount.clamp(0, 1).toDouble() : 1.0;
  int blendChannel(int shift) {
    final base = (baseArgb >> shift) & 0xff;
    final overlay = (overlayArgb >> shift) & 0xff;
    return (base + (overlay - base) * bounded).round().clamp(0, 255);
  }

  return 0xff000000 |
      (blendChannel(16) << 16) |
      (blendChannel(8) << 8) |
      blendChannel(0);
}

double colorContrastRatio(int firstArgb, int secondArgb) {
  final first = _relativeLuminance(firstArgb);
  final second = _relativeLuminance(secondArgb);
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + .05) / (darker + .05);
}

String cssColorFromArgb(int argb) {
  final value = argb & 0xffffffff;
  final alpha = ((value >> 24) & 0xff) / 255;
  final red = (value >> 16) & 0xff;
  final green = (value >> 8) & 0xff;
  final blue = value & 0xff;
  if (alpha >= .999) {
    return '#${red.toRadixString(16).padLeft(2, '0')}'
        '${green.toRadixString(16).padLeft(2, '0')}'
        '${blue.toRadixString(16).padLeft(2, '0')}';
  }
  return 'rgba($red,$green,$blue,${_cssNumber(alpha)})';
}

String buildNovelBackgroundCss({
  required Uri uri,
  required NovelBackgroundFit fit,
  required double strength,
}) {
  final opacity = strength.isFinite ? strength.clamp(0, 1).toDouble() : 1.0;
  final fitCss = switch (fit) {
    NovelBackgroundFit.crop =>
      'background-size:cover;background-position:center;background-repeat:no-repeat;',
    NovelBackgroundFit.tile =>
      'background-size:auto;background-position:left top;background-repeat:repeat;',
    NovelBackgroundFit.fill =>
      'background-size:100% 100%;background-position:center;background-repeat:no-repeat;',
  };
  return 'body{position:relative;isolation:isolate;background:transparent!important;}'
      'body::before{content:"";position:fixed;inset:0;z-index:-1;'
      'pointer-events:none;background-image:url("$uri");$fitCss'
      'opacity:${_cssNumber(opacity)};}';
}

double _relativeLuminance(int argb) {
  double channel(int shift) {
    final value = ((argb >> shift) & 0xff) / 255;
    return value <= .03928
        ? value / 12.92
        : math.pow((value + .055) / 1.055, 2.4).toDouble();
  }

  return .2126 * channel(16) + .7152 * channel(8) + .0722 * channel(0);
}

String _cssNumber(double value) {
  final fixed = value.toStringAsFixed(3);
  return fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
