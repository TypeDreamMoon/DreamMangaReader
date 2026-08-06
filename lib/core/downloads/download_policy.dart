import 'download_task.dart';

const int gibibyte = 1024 * 1024 * 1024;

final class DownloadPolicySettings {
  factory DownloadPolicySettings({
    bool wifiOnly = true,
    bool allowRoaming = false,
    int maxConcurrentWorks = 2,
    int reserveBytes = 2 * gibibyte,
    bool pauseOnLowBattery = false,
  }) {
    if (maxConcurrentWorks < 1 || maxConcurrentWorks > 3) {
      throw ArgumentError.value(
        maxConcurrentWorks,
        'maxConcurrentWorks',
        'must be between 1 and 3',
      );
    }
    if (reserveBytes < 0) {
      throw ArgumentError.value(reserveBytes, 'reserveBytes');
    }
    return DownloadPolicySettings._(
      wifiOnly: wifiOnly,
      allowRoaming: allowRoaming,
      maxConcurrentWorks: maxConcurrentWorks,
      reserveBytes: reserveBytes,
      pauseOnLowBattery: pauseOnLowBattery,
    );
  }

  const DownloadPolicySettings._({
    required this.wifiOnly,
    required this.allowRoaming,
    required this.maxConcurrentWorks,
    required this.reserveBytes,
    required this.pauseOnLowBattery,
  });

  final bool wifiOnly;
  final bool allowRoaming;
  final int maxConcurrentWorks;
  final int reserveBytes;
  final bool pauseOnLowBattery;
}

final class DownloadEnvironment {
  const DownloadEnvironment({
    required this.connected,
    required this.wifi,
    required this.metered,
    required this.roaming,
    required this.batteryLow,
    required this.storageAvailable,
    required this.freeBytes,
  });

  final bool connected;
  final bool wifi;
  final bool metered;
  final bool roaming;
  final bool batteryLow;
  final bool storageAvailable;
  final int freeBytes;

  DownloadEnvironment copyWith({
    bool? connected,
    bool? wifi,
    bool? metered,
    bool? roaming,
    bool? batteryLow,
    bool? storageAvailable,
    int? freeBytes,
  }) {
    return DownloadEnvironment(
      connected: connected ?? this.connected,
      wifi: wifi ?? this.wifi,
      metered: metered ?? this.metered,
      roaming: roaming ?? this.roaming,
      batteryLow: batteryLow ?? this.batteryLow,
      storageAvailable: storageAvailable ?? this.storageAvailable,
      freeBytes: freeBytes ?? this.freeBytes,
    );
  }
}

final class DownloadPolicyDecision {
  const DownloadPolicyDecision.allow()
      : allowed = true,
        pauseReason = null;

  const DownloadPolicyDecision.pause(this.pauseReason) : allowed = false;

  final bool allowed;
  final DownloadPauseReason? pauseReason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadPolicyDecision &&
          allowed == other.allowed &&
          pauseReason == other.pauseReason;

  @override
  int get hashCode => Object.hash(allowed, pauseReason);
}

DownloadPolicyDecision evaluateDownloadPolicy(
  DownloadPolicySettings settings,
  DownloadEnvironment environment,
) {
  if (!environment.storageAvailable) {
    return const DownloadPolicyDecision.pause(
      DownloadPauseReason.externalStorage,
    );
  }
  if (environment.freeBytes < settings.reserveBytes) {
    return const DownloadPolicyDecision.pause(DownloadPauseReason.storage);
  }
  if (!environment.connected) {
    return const DownloadPolicyDecision.pause(DownloadPauseReason.system);
  }
  if (environment.roaming && !settings.allowRoaming) {
    return const DownloadPolicyDecision.pause(DownloadPauseReason.roaming);
  }
  if (settings.wifiOnly && !environment.wifi) {
    return const DownloadPolicyDecision.pause(DownloadPauseReason.wifi);
  }
  if (settings.pauseOnLowBattery && environment.batteryLow) {
    return const DownloadPolicyDecision.pause(DownloadPauseReason.battery);
  }
  return const DownloadPolicyDecision.allow();
}
