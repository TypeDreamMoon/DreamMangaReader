import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:dream_manga_reader/core/update/update_release_client.dart';
import 'package:dream_manga_reader/core/update/update_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeReleaseClient implements UpdateReleaseClient {
  _FakeReleaseClient({
    required this.source,
    this.releases = const [],
    this.listError,
    Map<String, UpdateManifest>? manifests,
  }) : manifests = manifests ?? const {};

  @override
  final UpdateSource source;
  final List<RemoteRelease> releases;
  final UpdateSourceException? listError;
  final Map<String, UpdateManifest> manifests;

  @override
  Future<List<RemoteRelease>> listReleases() async {
    if (listError case final error?) throw error;
    return releases;
  }

  @override
  Future<RemoteRelease> loadAssets(RemoteRelease release) async => release;

  @override
  Future<UpdateManifest> fetchManifest(RemoteRelease release) async {
    final manifest = manifests[release.tag];
    if (manifest == null) {
      throw UpdateSourceException(source, 'Release is missing update manifest');
    }
    return manifest;
  }
}

RemoteRelease _release(
  UpdateSource source,
  String version, {
  bool prerelease = false,
  bool withManifest = true,
}) =>
    RemoteRelease(
      source: source,
      tag: 'v$version',
      pageUrl: 'https://example/${source.name}/v$version',
      notes: '$version notes',
      prerelease: prerelease,
      assets: [
        if (withManifest)
          const RemoteAsset(
            name: updateManifestAssetName,
            url: 'https://example/update.json',
            size: 200,
          ),
        const RemoteAsset(
          name: 'DreamMangaReader-android-universal.apk',
          url: 'https://example/app.apk',
          size: 12,
        ),
        const RemoteAsset(
          name: 'DreamMangaReader-windows-x64-setup.exe',
          url: 'https://example/setup.exe',
          size: 13,
        ),
      ],
    );

UpdateManifest _manifest(String version) => UpdateManifest.fromJson({
      'schemaVersion': 1,
      'appId': 'DreamMangaReader',
      'version': version,
      'channel': version.contains('-') ? 'beta' : 'stable',
      'assets': [
        {
          'platform': 'android',
          'arch': 'universal',
          'kind': 'installer',
          'fileName': 'DreamMangaReader-android-universal.apk',
          'sha256': 'a' * 64,
          'sizeBytes': 12,
        },
        {
          'platform': 'windows',
          'arch': 'x64',
          'kind': 'installer',
          'fileName': 'DreamMangaReader-windows-x64-setup.exe',
          'sha256': 'b' * 64,
          'sizeBytes': 13,
        },
      ],
    });

UpdateResolver _resolver({
  List<RemoteRelease> gitee = const [],
  List<RemoteRelease> github = const [],
  UpdateSourceException? giteeError,
  UpdateSourceException? githubError,
}) {
  final manifests = <String, UpdateManifest>{};
  for (final release in [...gitee, ...github]) {
    if (release.assets
        .any((asset) => asset.name.toLowerCase() == updateManifestAssetName)) {
      manifests[release.tag] = _manifest(release.tag.substring(1));
    }
  }
  return UpdateResolver(
    gitee: _FakeReleaseClient(
      source: UpdateSource.gitee,
      releases: gitee,
      listError: giteeError,
      manifests: manifests,
    ),
    github: _FakeReleaseClient(
      source: UpdateSource.github,
      releases: github,
      listError: githubError,
      manifests: manifests,
    ),
  );
}

UpdateSourceException _error(UpdateSource source) =>
    UpdateSourceException(source, 'network unavailable');

void main() {
  test('same version prefers Gitee', () async {
    final result = await _resolver(
      gitee: [_release(UpdateSource.gitee, '1.3.1')],
      github: [_release(UpdateSource.github, '1.3.1')],
    ).resolve(currentVersion: '1.3.0', preferred: UpdateSource.gitee);

    expect(result!.source, UpdateSource.gitee);
    expect(result.version, '1.3.1');
    expect(result.integrity, UpdateIntegrity.manifest);
  });

  test('higher GitHub version wins even when Gitee is preferred', () async {
    final result = await _resolver(
      gitee: [_release(UpdateSource.gitee, '1.3.1')],
      github: [_release(UpdateSource.github, '1.3.2')],
    ).resolve(currentVersion: '1.3.0', preferred: UpdateSource.gitee);

    expect(result!.source, UpdateSource.github);
    expect(result.version, '1.3.2');
  });

  test('same version follows an explicit GitHub preference', () async {
    final result = await _resolver(
      gitee: [_release(UpdateSource.gitee, '1.3.1')],
      github: [_release(UpdateSource.github, '1.3.1')],
    ).resolve(currentVersion: '1.3.0', preferred: UpdateSource.github);

    expect(result!.source, UpdateSource.github);
  });

  test('fallback survives preferred source failure', () async {
    final result = await _resolver(
      giteeError: _error(UpdateSource.gitee),
      github: [_release(UpdateSource.github, '1.3.1')],
    ).resolve(currentVersion: '1.3.0', preferred: UpdateSource.gitee);

    expect(result!.source, UpdateSource.github);
    expect(result.warnings.single, contains('Gitee'));
  });

  test('both source failures are not reported as up to date', () async {
    await expectLater(
      _resolver(
        giteeError: _error(UpdateSource.gitee),
        githubError: _error(UpdateSource.github),
      ).resolve(currentVersion: '1.3.0', preferred: UpdateSource.gitee),
      throwsA(isA<UpdateResolutionException>()),
    );
  });

  test('stable channel filters prereleases', () async {
    final result = await _resolver(
      gitee: [
        _release(UpdateSource.gitee, '1.4.0-beta.1', prerelease: true),
        _release(UpdateSource.gitee, '1.3.1'),
      ],
    ).resolve(currentVersion: '1.3.0', preferred: UpdateSource.gitee);

    expect(result!.version, '1.3.1');
  });

  test('prerelease clients continue receiving prereleases', () async {
    final result = await _resolver(
      gitee: [
        _release(UpdateSource.gitee, '1.4.0-beta.2', prerelease: true),
      ],
    ).resolve(
      currentVersion: '1.4.0-beta.1',
      preferred: UpdateSource.gitee,
    );

    expect(result!.version, '1.4.0-beta.2');
  });

  test('legacy GitHub release remains usable without a manifest', () async {
    final result = await _resolver(
      github: [
        _release(UpdateSource.github, '1.3.1', withManifest: false),
      ],
    ).resolve(currentVersion: '1.3.0', preferred: UpdateSource.gitee);

    expect(result!.source, UpdateSource.github);
    expect(result.integrity, UpdateIntegrity.legacy);
    expect(result.manifest, isNull);
    expect(result.assets, isNotEmpty);
  });

  test('invalid GitHub manifest does not downgrade to legacy integrity',
      () async {
    final giteeRelease = _release(UpdateSource.gitee, '1.3.1');
    final githubRelease = _release(UpdateSource.github, '1.3.2');
    final resolver = UpdateResolver(
      gitee: _FakeReleaseClient(
        source: UpdateSource.gitee,
        releases: [giteeRelease],
        manifests: {'v1.3.1': _manifest('1.3.1')},
      ),
      github: _FakeReleaseClient(
        source: UpdateSource.github,
        releases: [githubRelease],
      ),
    );

    final result = await resolver.resolve(
      currentVersion: '1.3.0',
      preferred: UpdateSource.gitee,
    );

    expect(result!.source, UpdateSource.gitee);
    expect(result.integrity, UpdateIntegrity.manifest);
    expect(result.warnings.single, contains('GitHub'));
  });

  test('returns null only when a source succeeds with no newer release',
      () async {
    final result = await _resolver(
      gitee: [_release(UpdateSource.gitee, '1.3.0')],
      githubError: _error(UpdateSource.github),
    ).resolve(currentVersion: '1.3.0', preferred: UpdateSource.gitee);

    expect(result, isNull);
  });
}
