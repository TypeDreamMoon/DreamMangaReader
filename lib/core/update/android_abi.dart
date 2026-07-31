import 'package:flutter/services.dart';

abstract interface class AndroidAbiProvider {
  Future<List<String>> supportedAbis();
}

class MethodChannelAndroidAbiProvider implements AndroidAbiProvider {
  const MethodChannelAndroidAbiProvider();

  static const _channel = MethodChannel('dream_manga_reader/platform');

  @override
  Future<List<String>> supportedAbis() async {
    try {
      final value = await _channel.invokeMethod<Object?>('supportedAbis');
      if (value is! List ||
          value.any((abi) => abi is! String || abi.trim().isEmpty)) {
        return const [];
      }
      return List.unmodifiable(value.cast<String>());
    } catch (_) {
      return const [];
    }
  }
}
