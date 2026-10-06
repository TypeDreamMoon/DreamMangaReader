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

  // [load] 完成前用户就改过的项。启动那一两百毫秒里点了主题或强调色的话:此刻
  // `_prefs` 还是 null,写不进磁盘;紧接着 load 又把旧存档读回来盖掉 —— 用户眼睁睁
  // 看着刚选的主题弹回去。记下谁被改过,load 收尾时对这些项反过来做:不读回存档,
  // 拿当前值补写一次盘。
  bool _variantPending = false;
  bool _accentPending = false;

  AppThemeVariant _variant;
  AppThemeVariant get variant => _variant;

  Color? _accent;

  /// 全局强调色;null = 跟随主题自带的青碧(深/浅两套本来就不是同一个值)。
  Color? get accent => _accent;

  set accent(Color? v) {
    if (v == _accent) return;
    _accent = v;
    if (_prefs == null) {
      _accentPending = true;
    } else {
      _persistAccent();
    }
    notifyListeners();
  }

  set variant(AppThemeVariant v) {
    if (v == _variant) return;
    _variant = v;
    if (_prefs == null) {
      _variantPending = true;
    } else {
      _prefs!.setString(_kVariant, v.name);
    }
    notifyListeners();
  }

  void _persistAccent() {
    final prefs = _prefs;
    if (prefs == null) return;
    final v = _accent;
    if (v == null) {
      prefs.remove(_kAccent);
    } else {
      prefs.setInt(_kAccent, v.toARGB32());
    }
  }

  /// 启动时读回保存的主题变体。**读回来的值不会盖掉用户在这之前刚选的**:
  /// 那种项改为把当前值补写进磁盘。
  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    var changed = false;

    if (_accentPending) {
      _persistAccent();
    } else {
      final argb = prefs.getInt(_kAccent);
      if (argb != null) {
        _accent = Color(argb);
        changed = true;
      }
    }

    if (_variantPending) {
      prefs.setString(_kVariant, _variant.name);
    } else {
      final name = prefs.getString(_kVariant);
      if (name != null) {
        final v = AppThemeVariant.values
            .firstWhere((x) => x.name == name, orElse: () => _variant);
        if (v != _variant) {
          _variant = v;
          changed = true;
        }
      }
    }

    _accentPending = false;
    _variantPending = false;
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
