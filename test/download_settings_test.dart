import 'package:dream_manga_reader/app/download_settings.dart';
import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('loads persisted values and exposes a policy snapshot', () async {
    SharedPreferences.setMockInitialValues({
      'downloads.policy.wifiOnly': false,
      'downloads.policy.allowRoaming': true,
      'downloads.policy.maxConcurrentWorks': 3,
      'downloads.policy.reserveGiB': 5,
      'downloads.policy.pauseOnLowBattery': true,
    });
    final settings = DownloadSettings();

    await settings.load();

    expect(settings.wifiOnly, isFalse);
    expect(settings.allowRoaming, isTrue);
    expect(settings.maxConcurrentWorks, 3);
    expect(settings.reserveGiB, 5);
    expect(settings.pauseOnLowBattery, isTrue);
    expect(settings.policy.reserveBytes, 5 * gibibyte);
    settings.dispose();
  });

  test('setters persist validated values', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = DownloadSettings();
    await settings.load();

    settings.wifiOnly = false;
    settings.allowRoaming = true;
    settings.maxConcurrentWorks = 1;
    settings.reserveGiB = 10;
    settings.pauseOnLowBattery = true;
    await Future<void>.delayed(Duration.zero);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('downloads.policy.wifiOnly'), isFalse);
    expect(preferences.getBool('downloads.policy.allowRoaming'), isTrue);
    expect(preferences.getInt('downloads.policy.maxConcurrentWorks'), 1);
    expect(preferences.getInt('downloads.policy.reserveGiB'), 10);
    expect(preferences.getBool('downloads.policy.pauseOnLowBattery'), isTrue);
    settings.dispose();
  });
}
