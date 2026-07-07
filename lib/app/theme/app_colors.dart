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

  // 深色系(OLED / Dark)共用同一套「内容色」——强调青碧、文字、语义色完全一致,
  // 只有底/面/线的深度不同(OLED 纯黑更沉、Dark 深灰更柔),换起来是同一副长相。

  /// OLED —— 纯黑,省电、沉浸;内容色与 Dark 统一。
  static const oled = AppPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF0C100F),
    elevated: Color(0xFF151C1A),
    line: Color(0xFF1E2724),
    textPrimary: Color(0xFFEAF1EF),
    textMuted: Color(0xFF8F9C98),
    accent: Color(0xFF22D3BD),
    accentSoft: Color(0xFF5CE9D8),
    onAccent: Color(0xFF04211D),
    downloaded: Color(0xFFE7B15A),
    brightness: Brightness.dark,
  );

  /// Dark —— 深灰,比 OLED 略亮,常规护眼夜间;内容色与 OLED 统一。
  static const dark = AppPalette(
    background: Color(0xFF15181B),
    surface: Color(0xFF1E2225),
    elevated: Color(0xFF282E31),
    line: Color(0xFF333A3D),
    textPrimary: Color(0xFFEAF1EF),
    textMuted: Color(0xFF8F9C98),
    accent: Color(0xFF22D3BD),
    accentSoft: Color(0xFF5CE9D8),
    onAccent: Color(0xFF04211D),
    downloaded: Color(0xFFE7B15A),
    brightness: Brightness.dark,
  );

  /// Light —— 明亮浅色;薄荷底 + 白面,淡青抬升层次,青碧强调更鲜亮。
  static const light = AppPalette(
    background: Color(0xFFF4FAF8),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFEBF4F1),
    line: Color(0xFFE0E9E6),
    textPrimary: Color(0xFF121D1A),
    textMuted: Color(0xFF5D6B66),
    accent: Color(0xFF0FA694),
    accentSoft: Color(0xFF14C6B2),
    onAccent: Color(0xFFFFFFFF),
    downloaded: Color(0xFFC8892C),
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
