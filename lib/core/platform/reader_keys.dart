import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 阅读器音量键翻页的平台通道(仅 Android)。
///
/// 原生侧在「开启且阅读器活跃」时拦截音量键、消费按键并回调翻页方向;桌面/iOS 为空实现。
/// dir: 1 = 下一页(音量下),-1 = 上一页(音量上)。
///
/// 回调按**栈**管理、激活状态按**引用计数**管理:漫画阅读器上面再叠一个小说阅读器时,
/// 上层接管音量键,上层退出后自动还给下层 —— 老实现的 `clearHandler()` 是全局清空,
/// 小说页一关就把底下漫画阅读器的音量翻页也一起关掉了。
class ReaderKeys {
  ReaderKeys._();

  static const _ch = MethodChannel('dream_manga_reader/reader_keys');

  /// 仅测试:覆盖平台判断,让桌面上的单元测试也能走通道逻辑。
  @visibleForTesting
  static bool? debugSupportedOverride;

  static final List<_ReaderKeyBinding> _stack = [];
  static int _activeCount = 0;

  static bool get _supported => debugSupportedOverride ?? Platform.isAndroid;

  /// 注册翻页回调,返回注销用的令牌。栈顶(最后注册的)才是当前生效的回调。
  static Object setHandler(void Function(int dir) onTurn) {
    final binding = _ReaderKeyBinding(onTurn);
    _stack.add(binding);
    if (_supported && _stack.length == 1) {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'volumeKey' && _stack.isNotEmpty) {
          _stack.last.onTurn(call.arguments == 'down' ? 1 : -1);
        }
        return null;
      });
    }
    return binding;
  }

  /// 注销 [token] 对应的回调(不传则弹掉栈顶),栈顶随之回到上一个注册者。
  static void clearHandler([Object? token]) {
    if (_stack.isEmpty) return;
    if (token == null) {
      _stack.removeLast();
    } else if (!_stack.remove(token)) {
      return;
    }
    if (_stack.isEmpty && _supported) _ch.setMethodCallHandler(null);
  }

  /// 告诉原生是否拦截音量键。引用计数:只有 0↔1 这两次跨越才真的发通道消息,
  /// 谁开谁关。失败(极旧引擎/无通道)静默忽略,不影响阅读。
  static Future<void> setActive(bool active) async {
    if (active) {
      if (_activeCount++ > 0) return;
    } else {
      if (_activeCount == 0 || --_activeCount > 0) return;
    }
    if (!_supported) return;
    try {
      await _ch.invokeMethod('setVolumeKeyPaging', active);
    } catch (_) {}
  }

  @visibleForTesting
  static void debugReset() {
    _stack.clear();
    _activeCount = 0;
    debugSupportedOverride = null;
  }
}

class _ReaderKeyBinding {
  _ReaderKeyBinding(this.onTurn);

  final void Function(int dir) onTurn;
}
