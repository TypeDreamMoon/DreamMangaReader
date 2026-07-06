// 回归测试:主题变体(OLED/Dark/Light)应持久化,重启后恢复(之前每次都回 OLED)。
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
}
