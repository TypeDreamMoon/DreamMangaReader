import 'dart:async';

import 'package:flutter/foundation.dart';

import '../log/app_log.dart';
import 'download_policy.dart';

/// 探不出可用空间时用的兜底值:大到任何 reserveBytes 都过得去。
/// 宁可多下,也不要因为探测失败把下载永久卡在「空间不足」。
const int unknownFreeBytes = 0x3FFFFFFFFFFFFFFF;

/// 判定「低电量」的阈值(百分比,含)。充电中一律不算低电。
const int lowBatteryPercent = 15;

/// 网络的计费属性 —— 下载策略只关心这三件事。
@immutable
final class DownloadNetworkStatus {
  const DownloadNetworkStatus({
    required this.connected,
    required this.unmetered,
    required this.roaming,
  });

  /// 探测不到时的兜底:当作已连、不计费、不漫游。
  static const unknown = DownloadNetworkStatus(
    connected: true,
    unmetered: true,
    roaming: false,
  );

  static const offline = DownloadNetworkStatus(
    connected: false,
    unmetered: false,
    roaming: false,
  );

  final bool connected;

  /// Wi-Fi / 以太网这类不按流量计费的连接 —— 对应策略里的 `wifiOnly`。
  final bool unmetered;
  final bool roaming;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadNetworkStatus &&
          connected == other.connected &&
          unmetered == other.unmetered &&
          roaming == other.roaming;

  @override
  int get hashCode => Object.hash(connected, unmetered, roaming);
}

@immutable
final class DownloadPowerStatus {
  const DownloadPowerStatus({required this.batteryLow});

  static const unknown = DownloadPowerStatus(batteryLow: false);

  final bool batteryLow;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadPowerStatus && batteryLow == other.batteryLow;

  @override
  int get hashCode => batteryLow.hashCode;
}

@immutable
final class DownloadStorageStatus {
  const DownloadStorageStatus({
    required this.available,
    required this.freeBytes,
  });

  static const unknown = DownloadStorageStatus(
    available: true,
    freeBytes: unknownFreeBytes,
  );

  final bool available;
  final int freeBytes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadStorageStatus &&
          available == other.available &&
          freeBytes == other.freeBytes;

  @override
  int get hashCode => Object.hash(available, freeBytes);
}

typedef DownloadNetworkProbe = Future<DownloadNetworkStatus> Function();
typedef DownloadPowerProbe = Future<DownloadPowerStatus> Function();
typedef DownloadStorageProbe = Future<DownloadStorageStatus> Function();

/// 下载环境的真实来源。
///
/// 在这之前 `_initialDownloadEnvironment` 是个恒真的桩(永远 Wi-Fi、永远不漫游、
/// 空间无限),于是设置页的「仅 Wi-Fi / 低电暂停 / 预留空间」三个开关全是摆设,
/// 全仓也没有任何网络监听 —— [DownloadCoordinator.reevaluate] 只在启动和改设置
/// 时被调一次。
///
/// 这里把三路探测(网络 / 电量 / 空间)收成一个 [DownloadEnvironment]:平台推
/// 送的变化(Android 的 NetworkCallback、battery_plus 的电池状态)立即刷新,再
/// 加一个兜底轮询;环境真的变了才 [notifyListeners],由外面接到
/// `coordinator.reevaluate()`。
///
/// **任何一路探不出来都退回「不限制」**,而不是退回「禁止」——探测本身出问题
/// 不该让用户的下载全体停摆。
final class DownloadEnvironmentProvider extends ChangeNotifier {
  DownloadEnvironmentProvider({
    DownloadNetworkProbe? network,
    DownloadPowerProbe? power,
    DownloadStorageProbe? storage,
    Iterable<Stream<void>> signals = const [],
    this.pollInterval = const Duration(seconds: 45),
  })  : _network = network,
        _power = power,
        _storage = storage,
        _signals = List.unmodifiable(signals);

  final DownloadNetworkProbe? _network;
  final DownloadPowerProbe? _power;
  final DownloadStorageProbe? _storage;
  final List<Stream<void>> _signals;

  /// 兜底轮询间隔:可用空间没有系统通知,漫游/计费状态在部分机型上也不推送。
  final Duration pollInterval;

  final List<StreamSubscription<void>> _subscriptions = [];
  final Set<String> _loggedProbeFailures = {};
  Timer? _timer;
  bool _started = false;
  bool _probed = false;
  bool _disposed = false;
  Future<void> _tail = Future.value();

  DownloadNetworkStatus _networkStatus = DownloadNetworkStatus.unknown;
  DownloadPowerStatus _powerStatus = DownloadPowerStatus.unknown;
  DownloadStorageStatus _storageStatus = DownloadStorageStatus.unknown;

  DownloadNetworkStatus get networkStatus => _networkStatus;
  DownloadPowerStatus get powerStatus => _powerStatus;
  DownloadStorageStatus get storageStatus => _storageStatus;

  DownloadEnvironment get current => DownloadEnvironment(
        connected: _networkStatus.connected,
        wifi: _networkStatus.unmetered,
        metered: !_networkStatus.unmetered,
        roaming: _networkStatus.roaming,
        batteryLow: _powerStatus.batteryLow,
        storageAvailable: _storageStatus.available,
        freeBytes: _storageStatus.freeBytes,
      );

  /// 给 [DownloadCoordinator] 的 `environment` 回调:读缓存,首次读时先探一遍。
  Future<DownloadEnvironment> read() async {
    if (!_probed && !_disposed) await refresh();
    return current;
  }

  /// 订阅平台推送 + 起兜底轮询,并完成第一次探测。重复调用是安全的。
  Future<void> start() async {
    if (_disposed || _started) return;
    _started = true;
    for (final signal in _signals) {
      _subscriptions.add(
        signal.listen(
          (_) => unawaited(refresh()),
          // 平台侧没实现/被拆掉时流会直接报错,吞掉即可,轮询还在。
          onError: (Object _) {},
          cancelOnError: false,
        ),
      );
    }
    if (pollInterval > Duration.zero) {
      _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    }
    await refresh();
  }

  /// 重新探测一遍;环境确实变了才通知监听者。
  Future<void> refresh() {
    Future<void> action() => _refresh();
    _tail = _tail.then((_) => action(), onError: (Object _) => action());
    return _tail;
  }

  Future<void> _refresh() async {
    if (_disposed) return;
    final network = await _probe('network', _network, _networkStatus);
    final power = await _probe('power', _power, _powerStatus);
    final storage = await _probe('storage', _storage, _storageStatus);
    if (_disposed) return;
    _probed = true;
    if (network == _networkStatus &&
        power == _powerStatus &&
        storage == _storageStatus) {
      return;
    }
    _networkStatus = network;
    _powerStatus = power;
    _storageStatus = storage;
    notifyListeners();
  }

  Future<T> _probe<T>(
    String label,
    Future<T> Function()? probe,
    T fallback,
  ) async {
    if (probe == null) return fallback;
    try {
      final value = await probe();
      _loggedProbeFailures.remove(label);
      return value;
    } on Object catch (error) {
      // 同一路探测只吵一次,免得轮询把日志刷满。
      if (_loggedProbeFailures.add(label)) {
        AppLog.i.warn(
          LogCat.download,
          '下载环境探测失败:$label',
          detail: '$error',
        );
      }
      return fallback;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    super.dispose();
  }
}
