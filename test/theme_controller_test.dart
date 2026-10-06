// 回归测试:主题变体(OLED/Dark/Light)应持久化,重启后恢复(之前每次都回 OLED)。
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/app/theme/theme_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ThemeController persists the selected variant across restarts', () async {
    SharedPreferences.setMockInitialValues({});

    final first = ThemeController();
    await first.load();
    expect(first.variant, AppThemeVariant.oled, reason: '无存档时用默认 OLED');

    first.variant = AppThemeVariant.light; // 切换并持久化

    // 模拟「退出再进」:新建一个 controller 读回存档。
    final restarted = ThemeController();
    await restarted.load();
    expect(restarted.variant, AppThemeVariant.light,
        reason: '重启后应恢复上次选择的主题,而不是回到 OLED');
  });

  // 回归:load() 是异步的,启动那一两百毫秒里改主题会落进「_prefs 还是 null」的
  // 窗口 —— 写不进盘,而且 load() 读回旧存档还会把它盖掉。
  test('a change made before load() survives it and still lands on disk',
      () async {
    SharedPreferences.setMockInitialValues({
      'theme.variant': AppThemeVariant.dark.name,
      'theme.accent': const Color(0xFF112233).toARGB32(),
    });

    final theme = ThemeController();
    final loading = theme.load(); // 还没 await:_prefs 仍是 null
    theme.variant = AppThemeVariant.light;
    theme.accent = const Color(0xFFAABBCC);
    await loading;

    // 存档里的 dark/0x112233 不能把用户刚选的盖掉。
    expect(theme.variant, AppThemeVariant.light);
    expect(theme.accent, const Color(0xFFAABBCC));

    // 而且真的落盘了 —— 下次启动读回来的是这一份。
    final restarted = ThemeController();
    await restarted.load();
    expect(restarted.variant, AppThemeVariant.light);
    expect(restarted.accent, const Color(0xFFAABBCC));
  });

  test('clearing the accent before load() also survives', () async {
    SharedPreferences.setMockInitialValues({
      'theme.accent': const Color(0xFF112233).toARGB32(),
    });

    final theme = ThemeController();
    final loading = theme.load();
    theme.accent = const Color(0xFFAABBCC);
    theme.accent = null; // 改回「跟随主题」
    await loading;

    expect(theme.accent, isNull);

    final restarted = ThemeController();
    await restarted.load();
    expect(restarted.accent, isNull, reason: '存档里的旧强调色应已被删掉');
  });

  test('an untouched controller still reads its saved values back', () async {
    SharedPreferences.setMockInitialValues({
      'theme.variant': AppThemeVariant.dark.name,
      'theme.accent': const Color(0xFF112233).toARGB32(),
    });

    final theme = ThemeController();
    await theme.load();
    expect(theme.variant, AppThemeVariant.dark);
    expect(theme.accent, const Color(0xFF112233));
  });
}
