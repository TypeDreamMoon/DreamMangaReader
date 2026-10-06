import 'dart:io';

import 'package:battery_plus/battery_plus.dart';

import '../platform/windows_download_environment.dart';
import 'android_download_environment_bridge.dart';
import 'download_environment_provider.dart';

/// 按平台组装 [DownloadEnvironmentProvider]:
///
/// * 网络 —— Android 走 ConnectivityManager 桥(带 NetworkCallback 推送),
///   Windows 走 wininet;其它平台不探测,按「不限制」处理。
/// * 电量 —— battery_plus(Android 与 Windows 都有实现),电池状态变化即刷新。
/// * 可用空间 —— Android 的 StatFs / Windows 的 GetDiskFreeSpaceEx,
///   看的是下载目录所在的分区,靠轮询刷新。
DownloadEnvironmentProvider createDownloadEnvironmentProvider({
  required Future<String> Function() storageRoot,
  Battery? battery,
  Duration pollInterval = const Duration(seconds: 45),
}) {
  final power = battery ?? Battery();
  final signals = <Stream<void>>[];
  DownloadNetworkProbe? network;
  DownloadStorageProbe? storage;
  if (Platform.isAndroid) {
    final bridge = AndroidDownloadEnvironmentBridge();
    network = bridge.readNetwork;
    storage = () async => bridge.readStorage(await storageRoot());
    signals.add(bridge.changes);
  } else if (Platform.isWindows) {
    network = WindowsDownloadEnvironment.readNetwork;
    storage = () async =>
        WindowsDownloadEnvironment.readStorage(await storageRoot());
  }
  signals.add(power.onBatteryStateChanged.map<void>((_) {}));
  return DownloadEnvironmentProvider(
    network: network,
    power: () => readBatteryPowerStatus(power),
    storage: storage,
    signals: signals,
    pollInterval: pollInterval,
  );
}

/// 接了外部电源就不算低电 —— 用户插着充电器时没道理还替他省电。
Future<DownloadPowerStatus> readBatteryPowerStatus(Battery battery) async {
  final state = await battery.batteryState;
  switch (state) {
    case BatteryState.charging:
    case BatteryState.full:
    case BatteryState.connectedNotCharging:
      return const DownloadPowerStatus(batteryLow: false);
    case BatteryState.discharging:
    case BatteryState.unknown:
      break;
  }
  final level = await battery.batteryLevel;
  return DownloadPowerStatus(batteryLow: level <= lowBatteryPercent);
}
