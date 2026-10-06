import 'dart:async';

import 'package:dream_manga_reader/core/downloads/android_download_environment_bridge.dart';
import 'package:dream_manga_reader/core/downloads/download_coordinator.dart';
import 'package:dream_manga_reader/core/downloads/download_environment_provider.dart';
import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('composes the environment out of the three probes', () async {
    final provider = DownloadEnvironmentProvider(
      network: () async => const DownloadNetworkStatus(
        connected: true,
        unmetered: false,
        roaming: true,
      ),
      power: () async => const DownloadPowerStatus(batteryLow: true),
      storage: () async =>
          const DownloadStorageStatus(available: true, freeBytes: 1024),
      pollInterval: Duration.zero,
    );
    addTearDown(provider.dispose);

    final environment = await provider.read();

    expect(environment.connected, isTrue);
    expect(environment.wifi, isFalse);
    expect(environment.metered, isTrue);
    expect(environment.roaming, isTrue);
    expect(environment.batteryLow, isTrue);
    expect(environment.storageAvailable, isTrue);
    expect(environment.freeBytes, 1024);
  });

  test('a failing probe falls back to unrestricted instead of blocking',
      () async {
    var attempts = 0;
    final provider = DownloadEnvironmentProvider(
      network: () async {
        attempts++;
        throw StateError('no connectivity service');
      },
      power: () async => throw StateError('no battery plugin'),
      storage: () async => throw StateError('no path provider'),
      pollInterval: Duration.zero,
    );
    addTearDown(provider.dispose);

    final environment = await provider.read();

    expect(attempts, 1);
    expect(environment.connected, isTrue);
    expect(environment.wifi, isTrue);
    expect(environment.roaming, isFalse);
    expect(environment.batteryLow, isFalse);
    expect(environment.storageAvailable, isTrue);
    expect(environment.freeBytes, unknownFreeBytes);
  });

  test('only a real change notifies listeners', () async {
    var status = DownloadNetworkStatus.unknown;
    final provider = DownloadEnvironmentProvider(
      network: () async => status,
      pollInterval: Duration.zero,
    );
    addTearDown(provider.dispose);
    var notifications = 0;
    provider.addListener(() => notifications++);

    await provider.start();
    await provider.refresh();
    expect(notifications, 0);

    status = const DownloadNetworkStatus(
      connected: true,
      unmetered: false,
      roaming: false,
    );
    await provider.refresh();
    expect(notifications, 1);

    await provider.refresh();
    expect(notifications, 1);
  });

  test('a platform signal refreshes the environment', () async {
    final signals = StreamController<void>.broadcast();
    addTearDown(signals.close);
    var unmetered = true;
    final provider = DownloadEnvironmentProvider(
      network: () async => DownloadNetworkStatus(
        connected: true,
        unmetered: unmetered,
        roaming: false,
      ),
      signals: [signals.stream],
      pollInterval: Duration.zero,
    );
    addTearDown(provider.dispose);
    await provider.start();
    expect(provider.current.wifi, isTrue);

    unmetered = false;
    signals.add(null);
    await pumpEventQueue();

    expect(provider.current.wifi, isFalse);
  });

  test('an erroring signal stream does not take the provider down', () async {
    final signals = StreamController<void>.broadcast();
    addTearDown(signals.close);
    final provider = DownloadEnvironmentProvider(
      network: () async => DownloadNetworkStatus.unknown,
      signals: [signals.stream],
      pollInterval: Duration.zero,
    );
    addTearDown(provider.dispose);
    await provider.start();

    signals.addError(MissingPluginException('battery_plus'));
    await pumpEventQueue();

    expect(provider.current.connected, isTrue);
  });

  test('an environment change pauses the queue through the coordinator',
      () async {
    var unmetered = true;
    final provider = DownloadEnvironmentProvider(
      network: () async => DownloadNetworkStatus(
        connected: true,
        unmetered: unmetered,
        roaming: false,
      ),
      pollInterval: Duration.zero,
    );
    addTearDown(provider.dispose);
    final repository = RecordingDownloadTaskRepository()
      ..loaded = [taskFixture()];
    final coordinator = DownloadCoordinator(
      repository: repository,
      environment: provider.read,
      settings: DownloadPolicySettings.new,
    );
    addTearDown(coordinator.dispose);
    provider.addListener(() => unawaited(coordinator.reevaluate()));
    await coordinator.load();
    await provider.start();

    expect(coordinator.tasks.single.state, DownloadTaskState.queued);

    unmetered = false;
    await provider.refresh();
    await pumpEventQueue();

    expect(coordinator.tasks.single.state, DownloadTaskState.paused);
    expect(coordinator.tasks.single.pauseReason, DownloadPauseReason.wifi);

    unmetered = true;
    await provider.refresh();
    await pumpEventQueue();

    expect(coordinator.tasks.single.state, DownloadTaskState.queued);
  });

  test('the android bridge maps the native payloads', () async {
    const method = MethodChannel('test/download_environment');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      return switch (call.method) {
        'network' => {
            'connected': true,
            'unmetered': false,
            'roaming': true,
          },
        'storage' => {'available': true, 'freeBytes': 4096},
        _ => null,
      };
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, null));
    final bridge = AndroidDownloadEnvironmentBridge(method: method);

    expect(
      await bridge.readNetwork(),
      const DownloadNetworkStatus(
        connected: true,
        unmetered: false,
        roaming: true,
      ),
    );
    expect(
      await bridge.readStorage('/data/downloads'),
      const DownloadStorageStatus(available: true, freeBytes: 4096),
    );
  });

  test('a disconnected native payload maps to offline', () async {
    const method = MethodChannel('test/download_environment_offline');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      return {'connected': false, 'unmetered': false, 'roaming': false};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, null));
    final bridge = AndroidDownloadEnvironmentBridge(method: method);

    expect(await bridge.readNetwork(), DownloadNetworkStatus.offline);
  });
}
