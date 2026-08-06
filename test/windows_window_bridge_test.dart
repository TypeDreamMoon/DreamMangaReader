import 'dart:async';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/core/platform/windows_window_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bridge deduplicates close behavior updates', () async {
    const channel = MethodChannel('test/windows_window');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final bridge = WindowsWindowBridge(channel: channel, enabled: true);

    await bridge.setCloseToTray(true);
    await bridge.setCloseToTray(true);
    await bridge.setCloseToTray(false);

    expect(calls.map((call) => call.method), [
      'setCloseToTray',
      'setCloseToTray',
    ]);
    expect(calls.map((call) => call.arguments), [true, false]);
  });

  test('bridge deduplicates concurrent close behavior updates', () async {
    const channel = MethodChannel('test/windows_window_concurrent');
    final calls = <MethodCall>[];
    final responses = <Completer<void>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final response = Completer<void>();
      responses.add(response);
      await response.future;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final bridge = WindowsWindowBridge(channel: channel, enabled: true);

    final first = bridge.setCloseToTray(true);
    final duplicate = bridge.setCloseToTray(true);
    final latest = bridge.setCloseToTray(false);
    await Future<void>.delayed(Duration.zero);

    expect(calls, hasLength(1));
    responses.single.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((call) => call.arguments), [true, false]);
    responses[1].complete();
    await Future.wait([first, duplicate, latest]);
  });

  test('close-to-tray preference is local and persists', () async {
    SharedPreferences.setMockInitialValues({'lib.closeToTray': false});
    final store = LibraryStore();
    await store.load();
    expect(store.closeToTray, isFalse);

    store.closeToTray = true;

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('lib.closeToTray'), isTrue);
    store.dispose();
  });
}
