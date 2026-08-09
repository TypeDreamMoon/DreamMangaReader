import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('亮强调色配深字、暗强调色配白字', () {
    // 青碧够亮 → 文字压成同色相的极深色,与内置的 #04211D 一个意思。
    final teal = AppPalette.dark.withAccent(const Color(0xFF22D3BD));
    expect(teal.onAccent.computeLuminance(), lessThan(0.1));
    // 近黑的强调色 → 只能转白字。
    final ink = AppPalette.dark.withAccent(const Color(0xFF101010));
    expect(ink.onAccent, const Color(0xFFFFFFFF));
  });

  test('挑什么强调色,按钮上的文字都读得出来', () {
    // 覆盖极端:近黑、近白、高饱和、灰。对比度按 WCAG 相对亮度算。
    const samples = [
      Color(0xFF000000),
      Color(0xFFFFFFFF),
      Color(0xFFFF0000),
      Color(0xFF0033AA),
      Color(0xFFFFFF00),
      Color(0xFF808080),
      Color(0xFF22D3BD),
    ];
    for (final variant in [AppPalette.oled, AppPalette.dark, AppPalette.light]) {
      for (final accent in samples) {
        final p = variant.withAccent(accent);
        final a = p.accent.computeLuminance();
        final b = p.onAccent.computeLuminance();
        final ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '强调色 $accent 上的文字对比度不足($ratio)');
      }
    }
  });

  test('accentSoft 比强调色亮,且没被削平成同一个色', () {
    for (final variant in [AppPalette.dark, AppPalette.light]) {
      final p = variant.withAccent(const Color(0xFF4C9AFF));
      expect(HSLColor.fromColor(p.accentSoft).lightness,
          greaterThan(HSLColor.fromColor(p.accent).lightness));
    }
  });

  // 番剧播放器的浮层面板底色恒为 #161616(不随主题走),选中高亮却跟着主题色。
  // 用户挑一个藏青/墨绿之类本身就很暗的强调色,直接拿来用会糊在面板上。
  test('浮在近黑面板上的强调色一律抬到看得清', () {
    const panel = Color(0xFF161616);
    const samples = [
      ...kAccentPresets,
      Color(0xFF000000),
      Color(0xFF101010), // 比面板还暗
      Color(0xFF0033AA), // 藏青
      Color(0xFF1B3A21), // 墨绿
      Color(0xFFFFFFFF),
      Color(0xFF808080),
    ];
    for (final accent in samples) {
      final lifted = ensureContrast(accent, panel);
      final a = lifted.computeLuminance();
      final b = panel.computeLuminance();
      final ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.0),
          reason: '强调色 $accent 在面板上看不清(对比度 $ratio)');
    }
  });

  test('本来就够亮的强调色不做无谓改动', () {
    const panel = Color(0xFF161616);
    for (final accent in kAccentPresets) {
      // 预设都是中高明度,面板上本来就够读,应当原样返回。
      expect(ensureContrast(accent, panel), accent, reason: '$accent 被动了');
    }
  });

  test('抬亮度不改色相', () {
    const navy = Color(0xFF0033AA);
    final lifted = ensureContrast(navy, const Color(0xFF161616));
    expect(HSLColor.fromColor(lifted).hue,
        closeTo(HSLColor.fromColor(navy).hue, 0.5));
    expect(HSLColor.fromColor(lifted).lightness,
        greaterThan(HSLColor.fromColor(navy).lightness));
  });

  test('其余 token 原样保留', () {
    final p = AppPalette.dark.withAccent(const Color(0xFFE05B5B));
    expect(p.background, AppPalette.dark.background);
    expect(p.textPrimary, AppPalette.dark.textPrimary);
    expect(p.statusFail, AppPalette.dark.statusFail);
    expect(p.brightness, Brightness.dark);
  });
}

double max(double a, double b) => a > b ? a : b;
double min(double a, double b) => a < b ? a : b;
