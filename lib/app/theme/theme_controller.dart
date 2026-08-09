import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

/// 全局主题变体状态(OLED / Dark / Light),供设置页切换、全 App 读取。
/// 选择会持久化到 SharedPreferences,重启后恢复(否则每次都回到默认 OLED)。
class ThemeController extends ChangeNotifier {
  ThemeController([this._variant = AppThemeVariant.oled]);

  static const _kVariant = 'theme.variant';
  static const _kAccent = 'theme.accent';
  SharedPreferences? _prefs;

  AppThemeVariant _variant;
  AppThemeVariant get variant => _variant;

  Color? _accent;

  /// 全局强调色;null = 跟随主题自带的青碧(深/浅两套本来就不是同一个值)。
  Color? get accent => _accent;

  set accent(Color? v) {
    if (v == _accent) return;
    _accent = v;
    if (v == null) {
      _prefs?.remove(_kAccent);
    } else {
      _prefs?.setInt(_kAccent, v.toARGB32());
    }
    notifyListeners();
  }

  set variant(AppThemeVariant v) {
    if (v == _variant) return;
    _variant = v;
    _prefs?.setString(_kVariant, v.name);
    notifyListeners();
  }

  /// 启动时读回保存的主题变体。
  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    var changed = false;
    final argb = prefs.getInt(_kAccent);
    if (argb != null) {
      _accent = Color(argb);
      changed = true;
    }
    final name = prefs.getString(_kVariant);
    if (name != null) {
      final v = AppThemeVariant.values
          .firstWhere((x) => x.name == name, orElse: () => _variant);
      if (v != _variant) {
        _variant = v;
        changed = true;
      }
    }
    if (changed) notifyListeners();
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
