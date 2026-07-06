import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

/// 全局主题变体状态(OLED / Dark / Light),供设置页切换、全 App 读取。
/// 选择会持久化到 SharedPreferences,重启后恢复(否则每次都回到默认 OLED)。
class ThemeController extends ChangeNotifier {
  ThemeController([this._variant = AppThemeVariant.oled]);

  static const _kVariant = 'theme.variant';
  SharedPreferences? _prefs;

  AppThemeVariant _variant;
  AppThemeVariant get variant => _variant;

  set variant(AppThemeVariant v) {
    if (v == _variant) return;
    _variant = v;
    _prefs?.setString(_kVariant, v.name);
    notifyListeners();
  }

  /// 启动时读回保存的主题变体。
  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kVariant);
    if (name == null) return;
    final v = AppThemeVariant.values
        .firstWhere((x) => x.name == name, orElse: () => _variant);
    if (v != _variant) {
      _variant = v;
      notifyListeners();
    }
  }
}

/// 把 [ThemeController] 下发到 widget 树,页面用 `ThemeScope.of(context)` 读写。
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope not found in context');
    return scope!.notifier!;
  }
}
