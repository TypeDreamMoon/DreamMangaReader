import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/downloads/download_policy.dart';

final class DownloadSettings extends ChangeNotifier {
  static const _wifiOnlyKey = 'downloads.policy.wifiOnly';
  static const _allowRoamingKey = 'downloads.policy.allowRoaming';
  static const _maxConcurrentKey = 'downloads.policy.maxConcurrentWorks';
  static const _reserveGiBKey = 'downloads.policy.reserveGiB';
  static const _lowBatteryKey = 'downloads.policy.pauseOnLowBattery';

  SharedPreferences? _preferences;
  bool _wifiOnly = true;
  bool _allowRoaming = false;
  int _maxConcurrentWorks = 2;
  int _reserveGiB = 2;
  bool _pauseOnLowBattery = false;

  bool get wifiOnly => _wifiOnly;
  bool get allowRoaming => _allowRoaming;
  int get maxConcurrentWorks => _maxConcurrentWorks;
  int get reserveGiB => _reserveGiB;
  bool get pauseOnLowBattery => _pauseOnLowBattery;

  DownloadPolicySettings get policy => DownloadPolicySettings(
        wifiOnly: _wifiOnly,
        allowRoaming: _allowRoaming,
        maxConcurrentWorks: _maxConcurrentWorks,
        reserveBytes: _reserveGiB * gibibyte,
        pauseOnLowBattery: _pauseOnLowBattery,
      );

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    _preferences = preferences;
    _wifiOnly = preferences.getBool(_wifiOnlyKey) ?? true;
    _allowRoaming = preferences.getBool(_allowRoamingKey) ?? false;
    _maxConcurrentWorks =
        (preferences.getInt(_maxConcurrentKey) ?? 2).clamp(1, 3);
    _reserveGiB = (preferences.getInt(_reserveGiBKey) ?? 2).clamp(0, 20);
    _pauseOnLowBattery = preferences.getBool(_lowBatteryKey) ?? false;
    notifyListeners();
  }

  set wifiOnly(bool value) {
    if (value == _wifiOnly) return;
    _wifiOnly = value;
    unawaited(_preferences?.setBool(_wifiOnlyKey, value));
    notifyListeners();
  }

  set allowRoaming(bool value) {
    if (value == _allowRoaming) return;
    _allowRoaming = value;
    unawaited(_preferences?.setBool(_allowRoamingKey, value));
    notifyListeners();
  }

  set maxConcurrentWorks(int value) {
    if (value < 1 || value > 3) throw ArgumentError.value(value, 'value');
    if (value == _maxConcurrentWorks) return;
    _maxConcurrentWorks = value;
    unawaited(_preferences?.setInt(_maxConcurrentKey, value));
    notifyListeners();
  }

  set reserveGiB(int value) {
    if (value < 0 || value > 20) throw ArgumentError.value(value, 'value');
    if (value == _reserveGiB) return;
    _reserveGiB = value;
    unawaited(_preferences?.setInt(_reserveGiBKey, value));
    notifyListeners();
  }

  set pauseOnLowBattery(bool value) {
    if (value == _pauseOnLowBattery) return;
    _pauseOnLowBattery = value;
    unawaited(_preferences?.setBool(_lowBatteryKey, value));
    notifyListeners();
  }
}

class DownloadSettingsScope extends InheritedNotifier<DownloadSettings> {
  const DownloadSettingsScope({
    super.key,
    required DownloadSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static DownloadSettings of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<DownloadSettingsScope>();
    assert(scope != null, 'DownloadSettingsScope not found');
    return scope!.notifier!;
  }
}
