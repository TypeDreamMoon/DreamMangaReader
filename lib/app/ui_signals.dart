import 'package:flutter/material.dart';

/// 详情页 / 阅读器把当前封面(主题)色发布到这里;全局背景 [AppBackground] 据此
/// 在这些页面把用户设的「混合色」往封面主题色混一点。**返回出去(栈空)→ 恢复设置的混合色**。
///
/// 用**栈**而非单值:详情 A →(推荐里)详情 B 时,B 出栈应恢复 A 的色而不是清空;
/// 详情→阅读器时阅读器沿用栈顶(详情)的色。每个页面 [push] 拿一个 token,
/// 就绪后 [update],dispose 时 [pop]。生效色恒为栈顶。
class DetailTint {
  DetailTint._();

  /// 当前生效的封面色(null = 无,用设置的混合色)。AppBackground 监听它。
  static final ValueNotifier<Color?> color = ValueNotifier<Color?>(null);

  static final List<_Entry> _stack = [];

  /// 入栈,返回 token(初始色可为 null,取色算好后 [update])。
  static Object push([Color? c]) {
    final e = _Entry(c);
    _stack.add(e);
    _recompute();
    return e.token;
  }

  static void update(Object token, Color? c) {
    for (final e in _stack) {
      if (identical(e.token, token)) {
        e.color = c;
        break;
      }
    }
    _recompute();
  }

  static void pop(Object token) {
    _stack.removeWhere((e) => identical(e.token, token));
    _recompute();
  }

  static void _recompute() {
    color.value = _stack.isEmpty ? null : _stack.last.color;
  }
}

class _Entry {
  _Entry(this.color);
  final Object token = Object();
  Color? color;
}
