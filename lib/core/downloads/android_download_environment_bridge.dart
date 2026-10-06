import 'package:flutter/services.dart';

import 'download_environment_provider.dart';

/// Android 侧的下载环境探测:ConnectivityManager 的计费/漫游能力,以及下载目录
/// 所在分区的可用空间(StatFs)。
///
/// 网络变化由原生的 `NetworkCallback` 通过 EventChannel 推上来 —— 只当作「该重新
/// 探一次了」的信号,真实数值仍走 MethodChannel 拉,免得两条路的口径不一致。
class AndroidDownloadEnvironmentBridge {
  AndroidDownloadEnvironmentBridge({
    this.method = const MethodChannel(_methodChannelName),
    this.events = const EventChannel(_eventChannelName),
  });

  static const _methodChannelName = 'dream_manga_reader/download_environment';
  static const _eventChannelName =
      'dream_manga_reader/download_environment/events';

  final MethodChannel method;
  final EventChannel events;

  Stream<void>? _changes;

  /// 网络变化信号(广播流,多次取到的是同一条)。
  Stream<void> get changes =>
      _changes ??= events.receiveBroadcastStream().map<void>((_) {});

  Future<DownloadNetworkStatus> readNetwork() async {
    final raw = await method.invokeMapMethod<String, Object?>('network');
    if (raw == null) return DownloadNetworkStatus.unknown;
    if (!_bool(raw['connected'], fallback: true)) {
      return DownloadNetworkStatus.offline;
    }
    return DownloadNetworkStatus(
      connected: true,
      unmetered: _bool(raw['unmetered'], fallback: true),
      roaming: _bool(raw['roaming'], fallback: false),
    );
  }

  Future<DownloadStorageStatus> readStorage(String path) async {
    final raw = await method.invokeMapMethod<String, Object?>(
      'storage',
      {'path': path},
    );
    if (raw == null) return DownloadStorageStatus.unknown;
    final free = raw['freeBytes'];
    return DownloadStorageStatus(
      available: _bool(raw['available'], fallback: true),
      freeBytes: free is int && free >= 0 ? free : unknownFreeBytes,
    );
  }
}

bool _bool(Object? value, {required bool fallback}) =>
    value is bool ? value : fallback;
