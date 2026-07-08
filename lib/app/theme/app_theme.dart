import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 三个主题变体。UI 里用 [AppThemeVariant.values] 渲染切换器。
enum AppThemeVariant {
  oled('OLED 纯黑', 'OLED', AppPalette.oled),
  dark('Dark 深灰', 'Dark', AppPalette.dark),
  light('Light 浅色', 'Light', AppPalette.light);

  const AppThemeVariant(this.label, this.shortLabel, this.palette);

  final String label;
  final String shortLabel;
  final AppPalette palette;
}

/// 字体族。要启用思源黑体:把字体文件放进 `assets/fonts/` 并在
/// `pubspec.yaml` 的 `flutter.fonts` 段声明 family: 'SourceHanSansSC'。
/// 未提供字体文件时,引用未声明的 family 会静默回退到系统默认字体,不报错。
const String kFontFamily = 'SourceHanSansSC';

/// 平台自带字体回退栈。没打包字体时,Flutter 逐字形沿此列表挑当前系统已装的
/// 干净黑体——避免 Windows 落到宋体/位图字体那种「怪」的观感(拉丁清爽、中文却发糊/带棱角)。
/// 每个平台会跳过列表里它没有的字体,取第一个命中的。
const List<String> kFontFallback = <String>[
  'Microsoft YaHei UI', // Windows 首选(清晰无衬线中文)
  'Microsoft YaHei',
  'Segoe UI', // Windows 拉丁
  'PingFang SC', // macOS / iOS 中文
  'Hiragino Sans GB',
  'Noto Sans CJK SC', // Android / Linux
  'Noto Sans SC',
  'Source Han Sans SC',
  'sans-serif',
];

/// 由某个主题变体构造 [ThemeData](Material 3)。
/// [controlRadius]:统一控件圆角(设置里可调,默认 14)。
/// [fontFamily]:桌面可指定字体族(空=用回退栈);始终带 [kFontFallback] 兜底。
ThemeData buildTheme(AppThemeVariant variant,
    {double controlRadius = 14, String fontFamily = ''}) {
  final p = variant.palette;
  final r = controlRadius;
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accentSoft,
    onSecondary: p.onAccent,
    error: const Color(0xFFE5533D),
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.textPrimary,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    // 透明:实际底色由全局 AppBackground 提供(无背景图时=主题底色,与以前一致)。
    scaffoldBackgroundColor: Colors.transparent,
    // 桌面选了字体就用它,否则 null → 交给回退栈逐字形选系统黑体。始终带回退兜底。
    fontFamily: fontFamily.isEmpty ? null : fontFamily,
    fontFamilyFallback: kFontFallback,
    dividerColor: p.line,
    extensions: <ThemeExtension<dynamic>>[AppTokens(palette: p, radius: r)],
  );

  return base.copyWith(
    // 全平台统一顺滑转场(桌面默认几乎无过渡,加上更有质感)。
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
    }),
    textTheme: base.textTheme.apply(
      bodyColor: p.textPrimary,
      displayColor: p.textPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        shape: shape,
      ),
    ),
    outlinedButtonTheme:
        OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: shape)),
    elevatedButtonTheme:
        ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: shape)),
    textButtonTheme:
        TextButtonThemeData(style: TextButton.styleFrom(shape: shape)),
    // 统一控件圆角:M3 组件跟随主题 shape 即可,不用逐个改。
    cardTheme: CardThemeData(shape: shape),
    // 拖动时的数值气泡画在根 Overlay 里,不吃桌面 UiScale 的 FittedBox 缩放 → 会错位飘走。
    // 各滑块本就在右侧显示数值,气泡多余,全局关掉。
    sliderTheme: const SliderThemeData(
      showValueIndicator: ShowValueIndicator.never,
    ),
    listTileTheme: ListTileThemeData(
      // 带描边的统一圆角:设置里的卡片式 ListTile 直接继承,不用各自写 shape。
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(r),
        side: BorderSide(color: p.line),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(r + 4)), // 弹窗略大更稳
      backgroundColor: p.surface,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      // 描边/分段线走 p.line(与每行卡片描边一致,不再吃 M3 默认的 onSurface 高对比);
      // 选中段用 accent@20% 淡填 + accent 文字/图标,与导航栏选中高亮同一套克制语言。
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(shape),
        side: WidgetStatePropertyAll(BorderSide(color: p.line)),
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? p.accent.withValues(alpha: 0.20)
                : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? p.accent : p.textMuted),
        iconColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? p.accent : p.textMuted),
        textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.w600)),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(r + 8))),
    ),
    popupMenuTheme: PopupMenuThemeData(shape: shape),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(r)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(r),
          borderSide: BorderSide(color: p.line)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(r),
          borderSide: BorderSide(color: p.accent)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent, // 填充交给 GlassSurface(毛玻璃)
      indicatorColor: p.accent.withValues(alpha: 0.20),
      // 选中高亮跟随控件圆角(不再是默认胶囊),观感与全局统一。
      indicatorShape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
      elevation: 0,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: p.textMuted),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? p.accent : p.textMuted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent, // 填充交给 GlassSurface(半透明面板)
      indicatorColor: p.accent.withValues(alpha: 0.20),
      // 选中项做成带描边的圆角「按钮」(不再是默认扁平胶囊),桌面导轨更有质感。
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(r),
        side: BorderSide(color: p.accent.withValues(alpha: 0.55), width: 1),
      ),
      selectedIconTheme: IconThemeData(color: p.accent),
      unselectedIconTheme: IconThemeData(color: p.textMuted),
      selectedLabelTextStyle:
          TextStyle(color: p.accent, fontSize: 11, fontWeight: FontWeight.w700),
      unselectedLabelTextStyle:
          TextStyle(color: p.textMuted, fontSize: 11),
    ),
  );
}
