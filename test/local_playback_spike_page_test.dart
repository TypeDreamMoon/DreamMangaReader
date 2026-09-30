import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/platform/local_media_bridge.dart';
import 'package:dream_manga_reader/features/spike/local_playback_spike_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel(LocalMediaBridge.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  String logOf(WidgetTester tester) =>
      tester.widget<SelectableText>(find.byType(SelectableText)).data ?? '';

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('非 Android 上说明本页只用于真机验证,且拒绝调用桥', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      home: LocalPlaybackSpikePage(
        bridge: LocalMediaBridge(channel: channel, isAndroid: false),
      ),
    ));

    expect(logOf(tester), contains('只用于 Android 真机验证'));

    await tap(tester, '① 选目录');
    expect(logOf(tester), contains('本地媒体桥仅支持 Android'));
  });

  testWidgets('Android 上按顺序走通 选目录 → 列子项 → openFd → 释放', (tester) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'pickDirectory':
          return <String, Object?>{
            'uri': 'content://com.android.externalstorage.documents/'
                'tree/primary%3AMovies',
            'name': 'Movies',
          };
        case 'listChildren':
          return <Object?>[
            <String, Object?>{
              'uri': 'content://tree/primary%3AMovies/document/E01.mkv',
              'name': 'E01.mkv',
              'mime': 'video/x-matroska',
              'size': 1024,
              'lastModified': 1700000000000,
            },
            <String, Object?>{
              'uri': 'content://tree/primary%3AMovies/document/E02.mkv',
              'name': 'E02.mkv',
              'mime': 'video/x-matroska',
              'size': 2048,
              'lastModified': 1700000001000,
            },
          ];
        case 'openFd':
          return <String, Object?>{'fd': 42, 'path': '/proc/self/fd/42'};
        default:
          return null;
      }
    });

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      home: LocalPlaybackSpikePage(
        bridge: LocalMediaBridge(channel: channel, isAndroid: true),
      ),
    ));

    await tap(tester, '① 选目录');
    expect(logOf(tester), contains('名称: Movies'));

    await tap(tester, '② 列子项');
    expect(logOf(tester), contains('共 2 个文件'));
    expect(logOf(tester), contains('E01.mkv'));

    await tap(tester, '④ openFd');
    expect(logOf(tester), contains('fd=42'));
    expect(logOf(tester), contains('/proc/self/fd/42'));
    // 测试跑在 Windows 上,直读 /proc/self/fd 不适用,页面应跳过而不是挂住。
    expect(logOf(tester), contains('跳过 Dart 直读检查'));

    await tap(tester, '⑥ 释放 fd');
    expect(logOf(tester), contains('已释放'));

    expect(calls, [
      'pickDirectory',
      'listChildren',
      'openFd',
      'releaseFd',
    ]);
  });
}
