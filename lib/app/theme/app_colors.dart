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
  final Color statusOk; // 语义:成功/在线(绿)
  final Color statusWarn; // 语义:警告/空(琥珀)
  final Color statusFail; // 语义:失败/错误(红)
  final Color bangumi; // Bangumi 品牌粉
  final Brightness brightness;

  // 语义状态色 + 品牌色跨主题一致(与各页此前硬编码的值相同),故给默认值,
  // 三套主题的 const 实例无需逐一声明。
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
    this.statusOk = const Color(0xFF3FB950),
    this.statusWarn = const Color(0xFFD9A441),
    this.statusFail = const Color(0xFFE5534B),
    this.bangumi = const Color(0xFFF09199),
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

  /// 换掉强调色,并据它**派生** [accentSoft] 与 [onAccent]。
  ///
  /// 用户在设置里能选任意颜色,这两个就不能再是常量:
  /// - [accentSoft] 是同色相提亮一档(高亮/发光用)。深色底上提得多些,浅色底上少些,
  ///   否则在白面上会淡到看不见。
  /// - [onAccent] 是**压在强调色上的文字色**,按强调色的**实际亮度**选深或浅,
  ///   而不是按主题走 —— 用户完全可能在深色主题下挑一个很暗的强调色,
  ///   那时文字必须转成浅色才读得出来(反之亦然)。
  AppPalette withAccent(Color value) {
    final hsl = HSLColor.fromColor(value);
    final lift = brightness == Brightness.dark ? 0.16 : 0.08;
    final soft = HSLColor.fromAHSL(
      1,
      hsl.hue,
      hsl.saturation,
      (hsl.lightness + lift).clamp(0.0, 0.92),
    ).toColor();
    // 深浅两个候选各算一次对比度,取高的那个。
    // 别用「亮度过某个阈值就配深字」那种一刀切 —— 高饱和的正红亮度只有 .21,
    // 按阈值会配白字,实测对比度才 4.0,达不到 WCAG AA 的 4.5。
    final deep = HSLColor.fromAHSL(
        1, hsl.hue, (hsl.saturation * 0.9).clamp(0.0, 1.0), 0.08).toColor();
    const pale = Color(0xFFFFFFFF);
    final on = _contrast(value, deep) >= _contrast(value, pale) ? deep : pale;
    return AppPalette(
      background: background,
      surface: surface,
      elevated: elevated,
      line: line,
      textPrimary: textPrimary,
      textMuted: textMuted,
      accent: value,
      accentSoft: soft,
      onAccent: on,
      downloaded: downloaded,
      brightness: brightness,
      statusOk: statusOk,
      statusWarn: statusWarn,
      statusFail: statusFail,
      bangumi: bangumi,
    );
  }
}

/// 把 [color] 顺着自己的色相挪明度,直到它在 [background] 上至少有
/// [minContrast] 的对比度;挪不到就退回纯白/纯黑里更能看清的那个。
///
/// 给的是**永远深色**的界面用的 —— 比如番剧播放器那块浮层面板,底色恒为近黑,
/// 不随主题走。用户挑的强调色可能本身就很暗(藏青、墨绿),直接拿来当选中色
/// 会糊在面板上看不出选没选中。
Color ensureContrast(
  Color color,
  Color background, {
  double minContrast = 4.0,
}) {
  if (_contrast(color, background) >= minContrast) return color;
  final hsl = HSLColor.fromColor(color);
  // 底暗就往亮里找,底亮就往暗里找。步长 0.04,最多走满整个明度区间。
  final up = background.computeLuminance() < 0.5;
  for (var step = 1; step <= 25; step++) {
    final lightness = (hsl.lightness + (up ? 1 : -1) * step * 0.04).clamp(0.0, 1.0);
    final candidate = hsl.withLightness(lightness).toColor();
    if (_contrast(candidate, background) >= minContrast) return candidate;
    if (lightness <= 0 || lightness >= 1) break;
  }
  const white = Color(0xFFFFFFFF);
  const black = Color(0xFF000000);
  return _contrast(white, background) >= _contrast(black, background)
      ? white
      : black;
}

/// WCAG 相对亮度对比度(1~21)。派生 onAccent 时用来在深/浅两个候选里挑。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 主题色预设。都是**显式覆盖**——「跟随主题」是另一档(accent = null),
/// 因为深色与浅色主题自带的青碧本来就不是同一个值。
const List<Color> kAccentPresets = <Color>[
  Color(0xFF22D3BD), // 青碧
  Color(0xFF4C9AFF), // 靛蓝
  Color(0xFF9B7BF0), // 藤紫
  Color(0xFFF0728F), // 樱
  Color(0xFFE58E3A), // 琥珀
  Color(0xFF5FBE72), // 竹绿
  Color(0xFFE05B5B), // 朱
  Color(0xFF6FB3C7), // 天青
];


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
