import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowsWindowBridge {
  WindowsWindowBridge({
    this.channel = const MethodChannel('dream_manga_reader/window'),
    bool? enabled,
  }) : enabled = enabled ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows);

  final MethodChannel channel;
  final bool enabled;
  bool? _lastCloseToTray;
  bool? _desiredCloseToTray;
  Future<void>? _syncFuture;

  Future<void> setCloseToTray(bool value) {
    if (!enabled) return Future.value();
    _desiredCloseToTray = value;
    if (_lastCloseToTray == value && _syncFuture == null) {
      return Future.value();
    }
    return _syncFuture ??= _drainCloseBehavior();
  }

  Future<void> _drainCloseBehavior() async {
    try {
      while (_lastCloseToTray != _desiredCloseToTray) {
        final value = _desiredCloseToTray!;
        await channel.invokeMethod<void>('setCloseToTray', value);
        _lastCloseToTray = value;
      }
    } finally {
      _syncFuture = null;
    }
  }
}
