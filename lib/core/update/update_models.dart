/// 更新来源。
enum UpdateSource { gitee, github }

/// 更新资产的可信级别。
enum UpdateIntegrity { manifest, legacy }

/// 更新资产面向的平台。
enum UpdatePlatform { windows, android }

/// 更新来源的显示信息和回退来源。
extension UpdateSourceInfo on UpdateSource {
  String get displayName => this == UpdateSource.gitee ? 'Gitee' : 'GitHub';

  UpdateSource get fallback =>
      this == UpdateSource.gitee ? UpdateSource.github : UpdateSource.gitee;
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
    this.parts = const [],
  });

  final UpdatePlatform platform;
  final String arch;
  final String kind;
  final String fileName;
  final String sha256;
  final int sizeBytes;
  final List<ManifestPart> parts;

  bool get isChunked => parts.isNotEmpty;
}

/// 由更新清单声明的文件分片。
class ManifestPart {
  const ManifestPart({
    required this.fileName,
    required this.sha256,
    required this.sizeBytes,
  });

  final String fileName;
  final String sha256;
  final int sizeBytes;
}

/// 已和远程 Release 附件绑定的文件分片。
class ResolvedUpdatePart {
  const ResolvedUpdatePart({
    required this.fileName,
    required this.sha256,
    required this.sizeBytes,
    required this.url,
    required this.sourceName,
  });

  final String fileName;
  final String sha256;
  final int sizeBytes;
  final String url;
  final String sourceName;
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
    this.url,
    this.sourceName,
    this.parts = const [],
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
        parts: const [],
      );

  factory ResolvedUpdateAsset.fromChunkedManifest(
    ManifestAsset asset, {
    required List<ResolvedUpdatePart> parts,
  }) =>
      ResolvedUpdateAsset(
        platform: asset.platform,
        arch: asset.arch,
        kind: asset.kind,
        fileName: asset.fileName,
        sha256: asset.sha256,
        sizeBytes: asset.sizeBytes,
        parts: List.unmodifiable(parts),
      );

  final UpdatePlatform platform;
  final String arch;
  final String kind;
  final String fileName;
  final String sha256;
  final int sizeBytes;
  final String? url;
  final String? sourceName;
  final List<ResolvedUpdatePart> parts;

  bool get isChunked => parts.isNotEmpty;
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
  static const _numericIdentifier = r'(?:0|[1-9]\d*)';
  static const _nonNumericIdentifier = r'(?:\d*[A-Za-z-][0-9A-Za-z-]*)';
  static const _prereleaseIdentifier =
      '(?:$_numericIdentifier|$_nonNumericIdentifier)';
  static final _versionPattern = RegExp(
    '^$_numericIdentifier\\.$_numericIdentifier\\.$_numericIdentifier'
    '(?:-$_prereleaseIdentifier(?:\\.$_prereleaseIdentifier)*)?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );
  static final _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

  final int schemaVersion;
  final String appId;
  final String version;
  final String channel;
  final List<ManifestAsset> assets;

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final schemaVersion = _requiredInt(json, 'schemaVersion');
    if (schemaVersion != 1 && schemaVersion != 2) {
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
      assets.add(
        _parseAsset(
          Map<String, dynamic>.from(rawAsset),
          schemaVersion: schemaVersion,
        ),
      );
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
  List<ResolvedUpdateAsset> resolve(
    UpdatePlatform platform,
    List<RemoteAsset> remoteAssets,
  ) {
    final manifestAssets =
        assets.where((asset) => asset.platform == platform).toList();
    if (manifestAssets.isEmpty) {
      throw const FormatException(
          'No update manifest asset for this platform.');
    }

    final remoteByName = <String, RemoteAsset>{};
    for (final remoteAsset in remoteAssets) {
      final key = _basename(remoteAsset.name).toLowerCase();
      if (remoteByName.containsKey(key)) {
        throw const FormatException('Release contains duplicate asset names.');
      }
      remoteByName[key] = remoteAsset;
    }

    return List.unmodifiable(manifestAssets.map((manifestAsset) {
      if (!manifestAsset.isChunked) {
        final remoteAsset = _resolveRemoteAsset(
          remoteByName,
          fileName: manifestAsset.fileName,
          sizeBytes: manifestAsset.sizeBytes,
        );
        return ResolvedUpdateAsset.fromManifest(
          manifestAsset,
          url: remoteAsset.url,
          sourceName: remoteAsset.name,
        );
      }

      final resolvedParts = manifestAsset.parts.map((part) {
        final remotePart = _resolveRemoteAsset(
          remoteByName,
          fileName: part.fileName,
          sizeBytes: part.sizeBytes,
        );
        return ResolvedUpdatePart(
          fileName: part.fileName,
          sha256: part.sha256,
          sizeBytes: part.sizeBytes,
          url: remotePart.url,
          sourceName: remotePart.name,
        );
      }).toList();
      return ResolvedUpdateAsset.fromChunkedManifest(
        manifestAsset,
        parts: resolvedParts,
      );
    }));
  }

  static RemoteAsset _resolveRemoteAsset(
    Map<String, RemoteAsset> remoteByName, {
    required String fileName,
    required int sizeBytes,
  }) {
    final remoteAsset = remoteByName[fileName.toLowerCase()];
    if (remoteAsset == null) {
      throw const FormatException('Release is missing a manifest asset.');
    }
    if (remoteAsset.size != sizeBytes) {
      throw const FormatException(
          'Release asset size does not match manifest.');
    }
    return remoteAsset;
  }

  static ManifestAsset _parseAsset(
    Map<String, dynamic> json, {
    required int schemaVersion,
  }) {
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

    final parts = _parseParts(
      json['parts'],
      schemaVersion: schemaVersion,
      fileName: fileName,
      sizeBytes: sizeBytes,
    );

    return ManifestAsset(
      platform: platform,
      arch: arch,
      kind: kind,
      fileName: fileName,
      sha256: sha256,
      sizeBytes: sizeBytes,
      parts: parts,
    );
  }

  static List<ManifestPart> _parseParts(
    Object? rawParts, {
    required int schemaVersion,
    required String fileName,
    required int sizeBytes,
  }) {
    if (rawParts == null) return const [];
    if (schemaVersion < 2 ||
        rawParts is! List ||
        rawParts.length < 2 ||
        rawParts.length > 64) {
      throw const FormatException('Invalid update manifest parts.');
    }

    final parts = <ManifestPart>[];
    final names = <String>{};
    var totalSize = 0;
    for (var index = 0; index < rawParts.length; index++) {
      final rawPart = rawParts[index];
      if (rawPart is! Map) {
        throw const FormatException('Invalid update manifest part.');
      }
      final json = Map<String, dynamic>.from(rawPart);
      final partFileName = _requiredString(json, 'fileName');
      final expectedFileName =
          '$fileName.part${(index + 1).toString().padLeft(3, '0')}';
      if (!_isSafeFileName(partFileName) || partFileName != expectedFileName) {
        throw const FormatException('Invalid update manifest part fileName.');
      }
      if (!names.add(partFileName.toLowerCase())) {
        throw const FormatException('Duplicate update manifest part.');
      }
      final partSha256 = _requiredString(json, 'sha256');
      if (!_sha256Pattern.hasMatch(partSha256)) {
        throw const FormatException('Invalid update manifest part SHA-256.');
      }
      final partSizeBytes = _requiredInt(json, 'sizeBytes');
      if (partSizeBytes <= 0) {
        throw const FormatException('Invalid update manifest part size.');
      }
      totalSize += partSizeBytes;
      parts.add(
        ManifestPart(
          fileName: partFileName,
          sha256: partSha256,
          sizeBytes: partSizeBytes,
        ),
      );
    }
    if (totalSize != sizeBytes) {
      throw const FormatException(
          'Update manifest part sizes do not match asset size.');
    }
    return List.unmodifiable(parts);
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
