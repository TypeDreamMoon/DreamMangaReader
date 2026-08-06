import 'dart:io';

import 'package:dream_manga_reader/features/anime/playback/hls_cache_settings.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_store.dart';
import 'package:dream_manga_reader/features/settings/settings_page.dart';
import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:dream_manga_reader/core/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('dmr-video-cache-settings-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('loads the 512 MiB default and persists an approved cache limit',
      () async {
    final settings = HlsCacheController(
      directoryProvider: () async => temp,
    );

    await settings.initialize();
    expect(settings.limit, HlsCacheLimit.mib512);

    await settings.setLimit(HlsCacheLimit.mib256);
    final restored = HlsCacheController(
      directoryProvider: () async => temp,
    );
    await restored.initialize();

    expect(restored.limit, HlsCacheLimit.mib256);
  });

  test('reports video cache bytes and clears only the video cache', () async {
    final settings = HlsCacheController(
      directoryProvider: () async => temp,
    );
    await settings.initialize();
    final unrelated =
        File('${temp.parent.path}${Platform.pathSeparator}keep.txt');
    await unrelated.writeAsString('keep');
    addTearDown(() async {
      if (await unrelated.exists()) await unrelated.delete();
    });

    await settings.cache.acquire(
      const HlsCacheRequest(
        url: 'https://media.example.test/segment.ts',
        authScope: 'public',
      ),
      (file) async {
        await file.writeAsBytes([1, 2, 3, 4], flush: true);
        return const CacheDownloadResult(
          contentType: 'video/mp2t',
          expectedLength: 4,
        );
      },
    ).then((lease) => lease.release());

    expect(await settings.sizeBytes(), 4);
    await settings.clear();
    expect(await settings.sizeBytes(), 0);
    expect(await unrelated.readAsString(), 'keep');
  });

  testWidgets('video cache panel changes the quota and clears cached bytes',
      (tester) async {
    final settings = _FakeVideoCacheController(bytes: 4);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: Scaffold(body: VideoCacheSettingsPanel(controller: settings)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('4 B'), findsOneWidget);
    await tester.tap(find.text('256 MiB'));
    await tester.pumpAndSettle();
    expect(settings.limit, HlsCacheLimit.mib256);

    await tester.tap(find.text('清理视频缓存'));
    await tester.pumpAndSettle();
    expect(await settings.sizeBytes(), 0);
    expect(find.textContaining('0 B'), findsOneWidget);
  });
}

class _FakeVideoCacheController implements VideoCacheSettingsController {
  _FakeVideoCacheController({required this.bytes});

  int bytes;
  @override
  HlsCacheLimit limit = HlsCacheLimit.defaultValue;

  @override
  Future<void> initialize() async {}
  @override
  Future<int> sizeBytes() async => bytes;
  @override
  Future<void> setLimit(HlsCacheLimit value) async => limit = value;
  @override
  Future<void> clear() async => bytes = 0;
}
