import 'android_abi.dart';
import 'update_models.dart';

class UpdateAssetSelector {
  const UpdateAssetSelector({
    this.abiProvider = const MethodChannelAndroidAbiProvider(),
  });

  final AndroidAbiProvider abiProvider;

  Future<ResolvedUpdateAsset?> select({
    required UpdatePlatform platform,
    required List<ResolvedUpdateAsset> assets,
    List<String>? supportedAbis,
  }) async {
    final installers = assets
        .where(
            (asset) => asset.platform == platform && asset.kind == 'installer')
        .toList();
    if (platform == UpdatePlatform.windows) {
      return _firstWhere(
        installers,
        (asset) => _isWindowsX64(asset.arch),
      );
    }

    final deviceAbis = supportedAbis ?? await abiProvider.supportedAbis();
    for (final rawAbi in deviceAbis) {
      final abi = _normalizeAbi(rawAbi);
      if (abi.isEmpty || abi == 'universal') continue;
      final matching = _firstWhere(
        installers,
        (asset) => _normalizeAbi(asset.arch) == abi,
      );
      if (matching != null) return matching;
    }
    return _firstWhere(
      installers,
      (asset) => _normalizeAbi(asset.arch) == 'universal',
    );
  }

  static ResolvedUpdateAsset? _firstWhere(
    List<ResolvedUpdateAsset> assets,
    bool Function(ResolvedUpdateAsset asset) matches,
  ) {
    for (final asset in assets) {
      if (matches(asset)) return asset;
    }
    return null;
  }

  static String _normalizeAbi(String value) {
    return switch (value.trim().toLowerCase()) {
      'aarch64' || 'arm64' || 'arm64-v8a' => 'arm64-v8a',
      'arm' || 'armv7' || 'armeabi-v7a' => 'armeabi-v7a',
      'amd64' || 'x64' || 'x86_64' => 'x86_64',
      final other => other,
    };
  }

  static bool _isWindowsX64(String value) => value == 'x64';
}
