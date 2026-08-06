import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

void main() {
  test('defaults match the approved conservative policy', () {
    final settings = DownloadPolicySettings();

    expect(settings.wifiOnly, isTrue);
    expect(settings.allowRoaming, isFalse);
    expect(settings.maxConcurrentWorks, 2);
    expect(settings.reserveBytes, 2 * gibibyte);
    expect(settings.pauseOnLowBattery, isFalse);
  });

  test('rejects unsupported concurrency and negative reserve', () {
    expect(
      () => DownloadPolicySettings(maxConcurrentWorks: 0),
      throwsArgumentError,
    );
    expect(
      () => DownloadPolicySettings(maxConcurrentWorks: 4),
      throwsArgumentError,
    );
    expect(
      () => DownloadPolicySettings(reserveBytes: -1),
      throwsArgumentError,
    );
  });

  test('wifi-only pauses a metered mobile task', () {
    final decision = evaluateDownloadPolicy(
      DownloadPolicySettings(),
      unrestrictedEnvironment.copyWith(wifi: false, metered: true),
    );

    expect(
      decision,
      const DownloadPolicyDecision.pause(DownloadPauseReason.wifi),
    );
  });

  test('roaming remains blocked when mobile downloads are allowed', () {
    final decision = evaluateDownloadPolicy(
      DownloadPolicySettings(wifiOnly: false),
      unrestrictedEnvironment.copyWith(
        wifi: false,
        metered: true,
        roaming: true,
      ),
    );

    expect(
      decision,
      const DownloadPolicyDecision.pause(DownloadPauseReason.roaming),
    );
  });

  test('storage and reserve failures have distinct pause reasons', () {
    expect(
      evaluateDownloadPolicy(
        DownloadPolicySettings(),
        unrestrictedEnvironment.copyWith(storageAvailable: false),
      ),
      const DownloadPolicyDecision.pause(
        DownloadPauseReason.externalStorage,
      ),
    );
    expect(
      evaluateDownloadPolicy(
        DownloadPolicySettings(),
        unrestrictedEnvironment.copyWith(freeBytes: gibibyte),
      ),
      const DownloadPolicyDecision.pause(DownloadPauseReason.storage),
    );
  });

  test('low battery pauses only when enabled', () {
    final lowBattery = unrestrictedEnvironment.copyWith(batteryLow: true);
    expect(
      evaluateDownloadPolicy(DownloadPolicySettings(), lowBattery),
      const DownloadPolicyDecision.allow(),
    );
    expect(
      evaluateDownloadPolicy(
        DownloadPolicySettings(pauseOnLowBattery: true),
        lowBattery,
      ),
      const DownloadPolicyDecision.pause(DownloadPauseReason.battery),
    );
  });

  test('unrestricted environment is allowed', () {
    expect(
      evaluateDownloadPolicy(
        DownloadPolicySettings(),
        unrestrictedEnvironment,
      ),
      const DownloadPolicyDecision.allow(),
    );
  });
}
