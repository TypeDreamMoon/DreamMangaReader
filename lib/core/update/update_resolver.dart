import 'update_models.dart';
import 'update_release_client.dart';

/// 可比较的严格语义化版本。
class UpdateVersion implements Comparable<UpdateVersion> {
  const UpdateVersion._(this.major, this.minor, this.patch, this.prerelease);

  static final _pattern = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;

  bool get isPrerelease => prerelease.isNotEmpty;

  String get normalized {
    final base = '$major.$minor.$patch';
    return prerelease.isEmpty ? base : '$base-${prerelease.join('.')}';
  }

  static UpdateVersion? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    final prerelease = match.group(4)?.split('.') ?? const <String>[];
    if (prerelease.any(
      (part) =>
          RegExp(r'^\d+$').hasMatch(part) &&
          part.length > 1 &&
          part.startsWith('0'),
    )) {
      return null;
    }
    return UpdateVersion._(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      List.unmodifiable(prerelease),
    );
  }

  static UpdateVersion parse(String value) =>
      tryParse(value) ?? (throw FormatException('Invalid version: $value'));

  @override
  int compareTo(UpdateVersion other) {
    for (final difference in [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ]) {
      if (difference != 0) return difference;
    }
    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;

    final length = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var index = 0; index < length; index++) {
      final left = prerelease[index];
      final right = other.prerelease[index];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      if (leftNumber != null && rightNumber != null) {
        final difference = leftNumber.compareTo(rightNumber);
        if (difference != 0) return difference;
      } else if (leftNumber != null) {
        return -1;
      } else if (rightNumber != null) {
        return 1;
      } else {
        final difference = left.compareTo(right);
        if (difference != 0) return difference;
      }
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}

/// 最终可展示或安装的更新候选。
class UpdateCandidate {
  const UpdateCandidate({
    required this.source,
    required this.version,
    required this.tag,
    required this.pageUrl,
    required this.notes,
    required this.prerelease,
    required this.assets,
    required this.integrity,
    this.manifest,
    this.warnings = const [],
  });

  final UpdateSource source;
  final String version;
  final String tag;
  final String pageUrl;
  final String notes;
  final bool prerelease;
  final List<RemoteAsset> assets;
  final UpdateIntegrity integrity;
  final UpdateManifest? manifest;
  final List<String> warnings;

  List<ResolvedUpdateAsset> resolveAssets(UpdatePlatform platform) {
    final currentManifest = manifest;
    if (currentManifest == null) return const [];
    return currentManifest.resolve(platform, assets);
  }

  UpdateCandidate withWarnings(List<String> value) => UpdateCandidate(
        source: source,
        version: version,
        tag: tag,
        pageUrl: pageUrl,
        notes: notes,
        prerelease: prerelease,
        assets: assets,
        integrity: integrity,
        manifest: manifest,
        warnings: List.unmodifiable(value),
      );
}

class UpdateResolutionException implements Exception {
  UpdateResolutionException(Iterable<UpdateSourceException> errors)
      : errors = List.unmodifiable(errors);

  final List<UpdateSourceException> errors;

  @override
  String toString() => errors.isEmpty
      ? 'Update resolution failed'
      : errors.map((error) => error.toString()).join('; ');
}

class UpdateResolver {
  const UpdateResolver({required this.gitee, required this.github});

  final UpdateReleaseClient gitee;
  final UpdateReleaseClient github;

  Future<UpdateCandidate?> resolve({
    required String currentVersion,
    required UpdateSource preferred,
    bool includeBeta = false,
  }) async {
    final current = UpdateVersion.parse(currentVersion);
    final allowPrerelease = includeBeta || current.isPrerelease;
    final clients = <UpdateSource, UpdateReleaseClient>{
      UpdateSource.gitee: gitee,
      UpdateSource.github: github,
    };
    final attempts = <_SourceAttempt>[];
    for (final source in [preferred, preferred.fallback]) {
      attempts.add(await _attempt(
        clients[source]!,
        current: current,
        includePrerelease: allowPrerelease,
      ));
    }

    final candidates = attempts
        .map((attempt) => attempt.candidate)
        .whereType<UpdateCandidate>()
        .toList();
    if (candidates.isEmpty) {
      final errors = attempts
          .map((attempt) => attempt.error)
          .whereType<UpdateSourceException>()
          .toList();
      if (errors.length == attempts.length) {
        throw UpdateResolutionException(errors);
      }
      return null;
    }

    var best = candidates.first;
    for (final candidate in candidates.skip(1)) {
      final comparison = UpdateVersion.parse(candidate.version)
          .compareTo(UpdateVersion.parse(best.version));
      if (comparison > 0 ||
          (comparison == 0 && candidate.source == preferred)) {
        best = candidate;
      }
    }
    final warnings = attempts
        .map((attempt) => attempt.error)
        .whereType<UpdateSourceException>()
        .map((error) => error.toString())
        .toList();
    return warnings.isEmpty ? best : best.withWarnings(warnings);
  }

  Future<_SourceAttempt> _attempt(
    UpdateReleaseClient client, {
    required UpdateVersion current,
    required bool includePrerelease,
  }) async {
    try {
      final releases = await client.listReleases();
      final newer = <(UpdateVersion, RemoteRelease)>[];
      for (final release in releases) {
        final version = UpdateVersion.tryParse(release.tag);
        if (version == null || version.compareTo(current) <= 0) continue;
        final prerelease = release.prerelease || version.isPrerelease;
        if (prerelease && !includePrerelease) continue;
        newer.add((version, release));
      }
      if (newer.isEmpty) return const _SourceAttempt.succeeded();
      newer.sort((left, right) => right.$1.compareTo(left.$1));

      final version = newer.first.$1;
      final release = await client.loadAssets(newer.first.$2);
      final hasManifest = release.assets.any(
        (asset) => asset.name.toLowerCase() == updateManifestAssetName,
      );
      if (!hasManifest) {
        if (client.source != UpdateSource.github) {
          throw UpdateSourceException(
            client.source,
            'Release is missing update manifest',
          );
        }
        final legacyAssets = release.assets.where(_isLegacyAsset).toList();
        if (legacyAssets.isEmpty) {
          throw UpdateSourceException(
            client.source,
            'Legacy Release has no installable asset',
          );
        }
        return _SourceAttempt.succeeded(
          UpdateCandidate(
            source: release.source,
            version: version.normalized,
            tag: release.tag,
            pageUrl: release.pageUrl,
            notes: release.notes,
            prerelease: release.prerelease || version.isPrerelease,
            assets: List.unmodifiable(legacyAssets),
            integrity: UpdateIntegrity.legacy,
          ),
        );
      }

      final manifest = await client.fetchManifest(release);
      final manifestVersion = UpdateVersion.parse(manifest.version);
      if (manifestVersion.compareTo(version) != 0) {
        throw UpdateSourceException(
          client.source,
          'Release tag and update manifest version differ',
        );
      }
      return _SourceAttempt.succeeded(
        UpdateCandidate(
          source: release.source,
          version: version.normalized,
          tag: release.tag,
          pageUrl: release.pageUrl,
          notes: release.notes,
          prerelease: release.prerelease || version.isPrerelease,
          assets: release.assets,
          integrity: UpdateIntegrity.manifest,
          manifest: manifest,
        ),
      );
    } on UpdateSourceException catch (error) {
      return _SourceAttempt.failed(error);
    } on Object catch (error) {
      return _SourceAttempt.failed(
        UpdateSourceException(
          client.source,
          'Could not resolve updates',
          cause: error,
        ),
      );
    }
  }

  static bool _isLegacyAsset(RemoteAsset asset) {
    final name = asset.name.toLowerCase();
    return name.endsWith('-universal.apk') || name.endsWith('setup.exe');
  }
}

class _SourceAttempt {
  const _SourceAttempt.succeeded([this.candidate]) : error = null;
  const _SourceAttempt.failed(this.error) : candidate = null;

  final UpdateCandidate? candidate;
  final UpdateSourceException? error;
}
