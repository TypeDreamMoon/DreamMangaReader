import 'package:flutter/services.dart';

/// 平台通道给不出设备 ABI 列表。
///
/// 这和「设备 ABI 一个都没匹配上」是两回事:后者说明这个来源没有本机架构的包,
/// 前者说明我们根本不知道设备是什么架构。以前两种情况都退化成一个空列表,
/// 于是通道一坏,所有设备都被悄悄导向通用包 —— 既看不出问题,
/// 也在通用包缺席时无从补救。区分开之后调用方才能各自处置。
class AndroidAbiUnavailableException implements Exception {
  const AndroidAbiUnavailableException(this.reason, {this.cause});

  final String reason;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'AndroidAbiUnavailableException: $reason'
      : 'AndroidAbiUnavailableException: $reason ($cause)';
}

abstract interface class AndroidAbiProvider {
  /// 设备支持的 ABI,按优先级从高到低。
  ///
  /// 拿不到时抛 [AndroidAbiUnavailableException],不返回空列表。
  Future<List<String>> supportedAbis();
}

class MethodChannelAndroidAbiProvider implements AndroidAbiProvider {
  const MethodChannelAndroidAbiProvider();

  static const _channel = MethodChannel('dream_manga_reader/platform');

  @override
  Future<List<String>> supportedAbis() async {
    Object? value;
    try {
      value = await _channel.invokeMethod<Object?>('supportedAbis');
    } on Object catch (error) {
      throw AndroidAbiUnavailableException('平台通道调用失败', cause: error);
    }
    if (value is! List) {
      throw const AndroidAbiUnavailableException('平台通道未返回 ABI 列表');
    }
    final abis = <String>[];
    for (final abi in value) {
      if (abi is! String || abi.trim().isEmpty) {
        throw const AndroidAbiUnavailableException('平台通道返回了无效的 ABI 条目');
      }
      abis.add(abi);
    }
    if (abis.isEmpty) {
      throw const AndroidAbiUnavailableException('平台通道返回了空 ABI 列表');
    }
    return List.unmodifiable(abis);
  }
}
