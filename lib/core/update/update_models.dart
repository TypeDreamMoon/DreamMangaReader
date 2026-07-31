/// 更新来源。
enum UpdateSource { gitee, github }

/// 更新资产的可信级别。
enum UpdateIntegrity { manifest, legacy }

/// 更新资产面向的平台。
enum UpdatePlatform { windows, android }

/// 更新来源的显示信息和回退来源。
class UpdateSourceInfo {
  const UpdateSourceInfo({required this.displayName, this.fallback});

  final String displayName;
  final UpdateSource? fallback;
}

/// 远程 Release 暴露的附件。
class RemoteAsset {
  const RemoteAsset({
    required this.name,
    required this.url,
    required this.size,
  });

  final String name;
  final String url;
  final int size;
}

/// 远程 Release 的标准化表示。
class RemoteRelease {
  const RemoteRelease({
    required this.source,
    required this.tag,
    required this.pageUrl,
    required this.notes,
    required this.prerelease,
    required this.assets,
  });

  final UpdateSource source;
  final String tag;
  final String pageUrl;
  final String notes;
  final bool prerelease;
  final List<RemoteAsset> assets;
}

/// 由发布清单声明的可更新附件。
class ManifestAsset {
  const ManifestAsset({
    required this.platform,
    required this.arch,
    required this.kind,
    required this.fileName,
    required this.sha256,
    required this.sizeBytes,
  });

  final UpdatePlatform platform;
  final String arch;
  final String kind;
  final String fileName;
  final String sha256;
  final int sizeBytes;
}

/// 已和远程 Release 附件绑定的更新资产。
class ResolvedUpdateAsset {
  const ResolvedUpdateAsset({
    required this.platform,
    required this.arch,
    required this.kind,
    required this.fileName,
    required this.sha256,
    required this.sizeBytes,
    required this.url,
    required this.sourceName,
  });

  factory ResolvedUpdateAsset.fromManifest(
    ManifestAsset asset, {
    required String url,
    required String sourceName,
  }) =>
      ResolvedUpdateAsset(
        platform: asset.platform,
        arch: asset.arch,
        kind: asset.kind,
        fileName: asset.fileName,
        sha256: asset.sha256,
        sizeBytes: asset.sizeBytes,
        url: url,
        sourceName: sourceName,
      );

  final UpdatePlatform platform;
  final String arch;
  final String kind;
  final String fileName;
  final String sha256;
  final int sizeBytes;
  final String url;
  final String sourceName;
}

/// 经版本、应用标识和附件完整性约束验证的更新清单。
class UpdateManifest {
  const UpdateManifest({
    required this.schemaVersion,
    required this.appId,
    required this.version,
    required this.channel,
    required this.assets,
  });

  static const _appId = 'DreamMangaReader';
  static final _versionPattern = RegExp(
    r'^\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)(?:\.\d+)?)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );
  static final _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

  final int schemaVersion;
  final String appId;
  final String version;
  final String channel;
  final List<ManifestAsset> assets;

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final schemaVersion = _requiredInt(json, 'schemaVersion');
    if (schemaVersion != 1) {
      throw const FormatException('Unsupported update manifest schemaVersion.');
    }

    final appId = _requiredString(json, 'appId');
    if (appId != _appId) {
      throw const FormatException('Unexpected update manifest appId.');
    }

    final version = _requiredString(json, 'version');
    if (!_versionPattern.hasMatch(version)) {
      throw const FormatException('Invalid update manifest version.');
    }

    final channel = _requiredString(json, 'channel');
    if (channel != 'stable' && channel != 'beta') {
      throw const FormatException('Invalid update manifest channel.');
    }

    final rawAssets = json['assets'];
    if (rawAssets is! List || rawAssets.isEmpty) {
      throw const FormatException('Update manifest assets must not be empty.');
    }
    final assets = <ManifestAsset>[];
    for (final rawAsset in rawAssets) {
      if (rawAsset is! Map) {
        throw const FormatException('Invalid update manifest asset.');
      }
      assets.add(_parseAsset(Map<String, dynamic>.from(rawAsset)));
    }

    return UpdateManifest(
      schemaVersion: schemaVersion,
      appId: appId,
      version: version,
      channel: channel,
      assets: List.unmodifiable(assets),
    );
  }

  /// 为 [platform] 的每个清单附件绑定同名远程附件。
  ///
  /// 附件名仅按不区分大小写的 basename 比较；远程大小必须与清单一致。
  ResolvedUpdateAsset resolve(
    UpdatePlatform platform,
    List<RemoteAsset> remoteAssets,
  ) {
    final manifestAsset = assets.cast<ManifestAsset?>().firstWhere(
          (asset) => asset!.platform == platform,
          orElse: () => null,
        );
    if (manifestAsset == null) {
      throw const FormatException(
          'No update manifest asset for this platform.');
    }

    final wantedName = manifestAsset.fileName.toLowerCase();
    RemoteAsset? remoteAsset;
    for (final candidate in remoteAssets) {
      if (_basename(candidate.name).toLowerCase() == wantedName) {
        remoteAsset = candidate;
        break;
      }
    }
    if (remoteAsset == null) {
      throw const FormatException('Release is missing a manifest asset.');
    }
    if (remoteAsset.size != manifestAsset.sizeBytes) {
      throw const FormatException(
          'Release asset size does not match manifest.');
    }

    return ResolvedUpdateAsset.fromManifest(
      manifestAsset,
      url: remoteAsset.url,
      sourceName: remoteAsset.name,
    );
  }

  static ManifestAsset _parseAsset(Map<String, dynamic> json) {
    final platform = switch (_requiredString(json, 'platform')) {
      'windows' => UpdatePlatform.windows,
      'android' => UpdatePlatform.android,
      _ => throw const FormatException('Invalid update manifest platform.'),
    };
    final arch = _requiredString(json, 'arch');
    final kind = _requiredString(json, 'kind');
    final fileName = _requiredString(json, 'fileName');
    if (!_isSafeFileName(fileName)) {
      throw const FormatException('Invalid update manifest fileName.');
    }
    final sha256 = _requiredString(json, 'sha256');
    if (!_sha256Pattern.hasMatch(sha256)) {
      throw const FormatException('Invalid update manifest SHA-256.');
    }
    final sizeBytes = _requiredInt(json, 'sizeBytes');
    if (sizeBytes <= 0) {
      throw const FormatException('Invalid update manifest asset size.');
    }

    return ManifestAsset(
      platform: platform,
      arch: arch,
      kind: kind,
      fileName: fileName,
      sha256: sha256,
      sizeBytes: sizeBytes,
    );
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing or invalid update manifest $key.');
    }
    return value;
  }

  static int _requiredInt(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! int) {
      throw FormatException('Missing or invalid update manifest $key.');
    }
    return value;
  }

  static bool _isSafeFileName(String value) =>
      value == _basename(value) &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !value.contains('..');

  static String _basename(String value) {
    final separator = value.lastIndexOf(RegExp(r'[\\/]'));
    return separator < 0 ? value : value.substring(separator + 1);
  }
}
