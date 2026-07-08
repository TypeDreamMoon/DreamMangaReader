import 'dart:io';

import 'package:flutter/services.dart';

/// 阅读器音量键翻页的平台通道(仅 Android)。
///
/// 原生侧在「开启且阅读器活跃」时拦截音量键、消费按键并回调翻页方向;桌面/iOS 为空实现。
/// dir: 1 = 下一页(音量下),-1 = 上一页(音量上)。
class ReaderKeys {
  ReaderKeys._();

  static const _ch = MethodChannel('dream_manga_reader/reader_keys');

  /// 注册翻页回调。多个阅读器叠加时,后注册者覆盖(始终指向当前活跃阅读器)。
  static void setHandler(void Function(int dir) onTurn) {
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'volumeKey') {
        onTurn(call.arguments == 'down' ? 1 : -1);
      }
      return null;
    });
  }

  static void clearHandler() {
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler(null);
  }

  /// 告诉原生是否拦截音量键。失败(极旧引擎/无通道)静默忽略,不影响阅读。
  static Future<void> setActive(bool active) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('setVolumeKeyPaging', active);
    } catch (_) {}
  }
}
