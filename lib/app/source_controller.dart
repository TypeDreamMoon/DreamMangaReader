import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/source/source_registry.dart';

/// 当前选中的源。书架/发现读它;源切换器改它。选择会持久化,重启后恢复
/// (否则每次都回到默认第一个源)。
class SourceController extends ChangeNotifier {
  // 引擎可能一个源都没加载(未配置源仓库)→ current 允许为空,UI 走「未配置源」空态。
  SourceController([SourceMeta? initial])
      : _current = initial ??
            (registeredSources.isEmpty ? null : registeredSources.first);

  static const _kSource = 'source.current';
  SharedPreferences? _prefs;

  SourceMeta? _current;
  SourceMeta? get current => _current;

  set current(SourceMeta? v) {
    if (v == null || v.id == _current?.id) return;
    _current = v;
    _prefs?.setString(_kSource, v.id);
    notifyListeners();
  }

  /// 启动时读回上次选中的源。
  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kSource);
    if (id == null) return;
    for (final s in registeredSources) {
      if (s.id == id) {
        if (s.id != _current?.id) {
          _current = s;
          notifyListeners();
        }
        return;
      }
    }
  }
}

/// 把 [SourceController] 下发到 widget 树,页面用 `SourceScope.of(context)` 读写。
class SourceScope extends InheritedNotifier<SourceController> {
  const SourceScope({
    super.key,
    required SourceController controller,
    required super.child,
  }) : super(notifier: controller);

  static SourceController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SourceScope>();
    assert(scope != null, 'SourceScope not found in context');
    return scope!.notifier!;
  }
}
