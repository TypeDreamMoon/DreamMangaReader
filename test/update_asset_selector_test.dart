import 'package:dream_manga_reader/core/update/android_abi.dart';
import 'package:dream_manga_reader/core/update/update_asset_selector.dart';
import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ResolvedUpdateAsset _asset({
  required UpdatePlatform platform,
  required String arch,
  required String kind,
  required String fileName,
}) =>
    ResolvedUpdateAsset(
      platform: platform,
      arch: arch,
      kind: kind,
      fileName: fileName,
      sha256: 'a' * 64,
      sizeBytes: 12,
      url: 'https://example/$fileName',
      sourceName: fileName,
    );

class _FakeAndroidAbiProvider implements AndroidAbiProvider {
  const _FakeAndroidAbiProvider(this.abis);

  final List<String> abis;

  @override
  Future<List<String>> supportedAbis() async => abis;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final selector = UpdateAssetSelector();
  final windowsZip = _asset(
    platform: UpdatePlatform.windows,
    arch: 'x64',
    kind: 'portable',
    fileName: 'DreamMangaReader-windows-x64.zip',
  );
  final windowsSetup = _asset(
    platform: UpdatePlatform.windows,
    arch: 'x64',
    kind: 'installer',
    fileName: 'DreamMangaReader-windows-x64-setup.exe',
  );
  final armV7 = _asset(
    platform: UpdatePlatform.android,
    arch: 'armeabi-v7a',
    kind: 'installer',
    fileName: 'DreamMangaReader-android-armeabi-v7a.apk',
  );
  final arm64 = _asset(
    platform: UpdatePlatform.android,
    arch: 'arm64-v8a',
    kind: 'installer',
    fileName: 'DreamMangaReader-android-arm64-v8a.apk',
  );
  final universal = _asset(
    platform: UpdatePlatform.android,
    arch: 'universal',
    kind: 'installer',
    fileName: 'DreamMangaReader-android-universal.apk',
  );

  test('Windows selects installer, never portable ZIP', () async {
    final selected = await selector.select(
      platform: UpdatePlatform.windows,
      assets: [windowsZip, windowsSetup],
    );

    expect(selected, same(windowsSetup));
  });

  for (final alias in ['amd64', 'x86_64']) {
    test('Windows rejects $alias architecture alias', () async {
      final selected = await selector.select(
        platform: UpdatePlatform.windows,
        assets: [
          _asset(
            platform: UpdatePlatform.windows,
            arch: alias,
            kind: 'installer',
            fileName: 'DreamMangaReader-windows-$alias-setup.exe',
          ),
        ],
      );

      expect(selected, isNull);
    });
  }

  test('Android follows supported ABI order', () async {
    final selected = await selector.select(
      platform: UpdatePlatform.android,
      assets: [armV7, arm64, universal],
      supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
    );

    expect(selected, same(arm64));
  });

  test('Android uses universal only when no ABI asset matches', () async {
    final selected = await selector.select(
      platform: UpdatePlatform.android,
      assets: [universal],
      supportedAbis: ['arm64-v8a'],
    );

    expect(selected, same(universal));
  });

  test('Android ignores universal pseudo ABI until real ABI matching ends',
      () async {
    final selected = await selector.select(
      platform: UpdatePlatform.android,
      assets: [universal, arm64],
      supportedAbis: ['universal', 'arm64-v8a'],
    );

    expect(selected, same(arm64));
  });

  test('Android selection uses the injected ABI provider', () async {
    final selected = await const UpdateAssetSelector(
      abiProvider: _FakeAndroidAbiProvider(['arm64-v8a']),
    ).select(
      platform: UpdatePlatform.android,
      assets: [armV7, arm64, universal],
    );

    expect(selected, same(arm64));
  });

  test('normalizes Android ABI aliases before matching', () async {
    final selected = await selector.select(
      platform: UpdatePlatform.android,
      assets: [arm64, universal],
      supportedAbis: ['aarch64'],
    );

    expect(selected, same(arm64));
  });

  test('does not guess an asset with incompatible metadata', () async {
    final selected = await selector.select(
      platform: UpdatePlatform.windows,
      assets: [windowsZip, arm64],
    );

    expect(selected, isNull);
  });

  test('ABI provider returns empty list for arbitrary channel exception',
      () async {
    const channel = MethodChannel('dream_manga_reader/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(channel.name, (_) => throw StateError('failed'));
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(channel.name, null),
    );

    final abis = await const MethodChannelAndroidAbiProvider().supportedAbis();

    expect(abis, isEmpty);
  });

  test('ABI provider returns empty list for unexpected channel values',
      () async {
    const channel = MethodChannel('dream_manga_reader/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => ['arm64-v8a', 42]);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final abis = await const MethodChannelAndroidAbiProvider().supportedAbis();

    expect(abis, isEmpty);
  });

  test('ABI provider decodes a valid string list', () async {
    const channel = MethodChannel('dream_manga_reader/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (_) async => ['arm64-v8a', 'armeabi-v7a'],
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final abis = await const MethodChannelAndroidAbiProvider().supportedAbis();

    expect(abis, ['arm64-v8a', 'armeabi-v7a']);
  });

  test('ABI provider rejects whitespace-only values', () async {
    const channel = MethodChannel('dream_manga_reader/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => ['arm64-v8a', '   ']);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final abis = await const MethodChannelAndroidAbiProvider().supportedAbis();

    expect(abis, isEmpty);
  });
}
