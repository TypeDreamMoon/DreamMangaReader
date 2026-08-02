import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/source/source_registry.dart';

/// 当前选中的源。书架/发现读它;源切换器改它。选择会持久化,重启后恢复
/// (否则每次都回到默认第一个源)。
class SourceController extends ChangeNotifier {
  SourceController([SourceMeta? initial]) {
    for (final kind in _kKinds) {
      _currentByKind[kind] = _firstFor(kind);
    }
    if (initial != null) _currentByKind[initial.kind] = initial;
  }

  static const _kSource = 'source.current';
  static const _kKinds = ['manga', 'anime', 'novel'];
  SharedPreferences? _prefs;

  final Map<String, SourceMeta?> _currentByKind = {};

  SourceMeta? get current => currentFor('manga');

  set current(SourceMeta? v) {
    if (v == null) return;
    selectFor('manga', v);
  }

  SourceMeta? currentFor(String kind) {
    _requireKind(kind);
    final current = _currentByKind[kind];
    if (current != null) {
      for (final source in registeredSources) {
        if (source.id == current.id && source.kind == kind) {
          return source;
        }
      }
    }
    return _firstFor(kind);
  }

  void selectFor(String kind, SourceMeta meta) {
    _requireKind(kind);
    if (meta.kind != kind) {
      throw ArgumentError.value(meta.kind, 'meta.kind', 'expected $kind');
    }
    final previous = _currentByKind[kind];
    if (identical(previous, meta)) return;
    _currentByKind[kind] = meta;
    if (previous?.id != meta.id) {
      _prefs?.setString('$_kSource.$kind', meta.id);
    }
    notifyListeners();
  }

  /// 启动时读回上次选中的源。
  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    final mangaKey = '$_kSource.manga';
    final legacyId = prefs.getString(_kSource);
    if (prefs.getString(mangaKey) == null && legacyId != null) {
      await prefs.setString(mangaKey, legacyId);
    }

    var changed = false;
    for (final kind in _kKinds) {
      final id = prefs.getString('$_kSource.$kind');
      if (id == null) continue;
      for (final source in registeredSources) {
        if (source.id == id && source.kind == kind) {
          if (!identical(_currentByKind[kind], source)) {
            _currentByKind[kind] = source;
            changed = true;
          }
          break;
        }
      }
    }
    if (changed) notifyListeners();
  }

  SourceMeta? _firstFor(String kind) {
    for (final source in registeredSources) {
      if (source.kind == kind) return source;
    }
    return null;
  }

  static void _requireKind(String kind) {
    if (!_kKinds.contains(kind)) {
      throw ArgumentError.value(kind, 'kind', 'unsupported source kind');
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
