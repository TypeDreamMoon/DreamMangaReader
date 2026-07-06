import 'package:flutter/material.dart';

/// 一套主题的颜色 token,对应设计稿 `docs/design/视觉方向.html`。
///
/// 三主题(OLED / Dark / Light)共用同一批语义 token,只是取值不同——
/// 这样组件里只引用语义(background / surface / accent…),换主题即换整套。
@immutable
class AppPalette {
  final Color background; // 底色 --ink
  final Color surface; // 面/卡片 --sumi
  final Color elevated; // 抬升 --sumi2
  final Color line; // 分隔线 --line
  final Color textPrimary; // 主文字 --text
  final Color textMuted; // 次文字 --mute
  final Color accent; // 青碧强调
  final Color accentSoft; // 青碧亮变体(高亮/发光)
  final Color onAccent; // 强调色上的文字
  final Color downloaded; // 语义:已下载(琥珀)
  final Brightness brightness;

  const AppPalette({
    required this.background,
    required this.surface,
    required this.elevated,
    required this.line,
    required this.textPrimary,
    required this.textMuted,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.downloaded,
    required this.brightness,
  });

  /// OLED —— 纯黑,省电、沉浸。
  static const oled = AppPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF0C100F),
    elevated: Color(0xFF151C1A),
    line: Color(0xFF1E2724),
    textPrimary: Color(0xFFECF3F1),
    textMuted: Color(0xFF8A9793),
    accent: Color(0xFF17D0BA),
    accentSoft: Color(0xFF4EE7D5),
    onAccent: Color(0xFF03201D),
    downloaded: Color(0xFFE7B15A),
    brightness: Brightness.dark,
  );

  /// Dark —— 深灰,比 OLED 略亮,常规护眼夜间。
  static const dark = AppPalette(
    background: Color(0xFF15181B),
    surface: Color(0xFF1E2225),
    elevated: Color(0xFF282E31),
    line: Color(0xFF333A3D),
    textPrimary: Color(0xFFEAF0EE),
    textMuted: Color(0xFF93A0A0),
    accent: Color(0xFF22D3BD),
    accentSoft: Color(0xFF5CE9D8),
    onAccent: Color(0xFF04211D),
    downloaded: Color(0xFFE7B15A),
    brightness: Brightness.dark,
  );

  /// Light —— 浅色;青碧加深以保证在白底上的对比度。
  static const light = AppPalette(
    background: Color(0xFFF5F7F5),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    line: Color(0xFFE4E8E6),
    textPrimary: Color(0xFF161B1A),
    textMuted: Color(0xFF68736F),
    accent: Color(0xFF0E9E8E),
    accentSoft: Color(0xFF0B8577),
    onAccent: Color(0xFFFFFFFF),
    downloaded: Color(0xFFC88A2E),
    brightness: Brightness.light,
  );
}

/// 把当前 [AppPalette] + 控件圆角挂到 [ThemeData] 上,组件通过 `context.palette`
/// / `context.radius` 取用。圆角随设置里的「控件圆角」联动(主题重建时更新)。
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  final AppPalette palette;
  final double radius; // 统一控件圆角
  const AppTokens({required this.palette, this.radius = 14});

  @override
  AppTokens copyWith({AppPalette? palette, double? radius}) =>
      AppTokens(palette: palette ?? this.palette, radius: radius ?? this.radius);

  // 主题切换是离散的,不做插值(避免中间态出现奇怪的过渡色)。
  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) => this;
}

extension AppPaletteX on BuildContext {
  AppTokens get _tokens => Theme.of(this).extension<AppTokens>()!;
  AppPalette get palette => _tokens.palette;

  /// 统一控件圆角(设置可调)。自定义卡片/容器用 `BorderRadius.circular(context.radius)`。
  double get radius => _tokens.radius;
}
