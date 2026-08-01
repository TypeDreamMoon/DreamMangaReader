import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const checksum =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  Map<String, dynamic> manifestJson({
    Object schemaVersion = 1,
    String appId = 'DreamMangaReader',
    String version = '1.2.3-beta.1+5',
    String channel = 'beta',
    String fileName = 'DreamMangaReader-setup.exe',
    String sha256 = checksum,
    int sizeBytes = 1024,
    List<Map<String, Object>>? parts,
  }) =>
      {
        'schemaVersion': schemaVersion,
        'appId': appId,
        'version': version,
        'channel': channel,
        'assets': [
          {
            'platform': 'windows',
            'arch': 'x64',
            'kind': 'installer',
            'fileName': fileName,
            'sha256': sha256,
            'sizeBytes': sizeBytes,
            if (parts != null) 'parts': parts,
          },
        ],
      };

  test('parses a supported release manifest', () {
    final manifest = UpdateManifest.fromJson(manifestJson());

    expect(manifest.schemaVersion, 1);
    expect(manifest.appId, 'DreamMangaReader');
    expect(manifest.version, '1.2.3-beta.1+5');
    expect(manifest.channel, 'beta');
    expect(manifest.assets, hasLength(1));
    expect(manifest.assets.single.platform, UpdatePlatform.windows);
    expect(manifest.assets.single.arch, 'x64');
  });

  test('binds an asset to a remote URL by case-insensitive basename', () {
    final manifest = UpdateManifest.fromJson(manifestJson());
    final resolved = manifest.resolve(
      UpdatePlatform.windows,
      [
        const RemoteAsset(
          name: 'DREAMMANGAREADER-SETUP.EXE',
          url: 'https://downloads.example/setup.exe',
          size: 1024,
        ),
      ],
    ).single;

    expect(resolved.url, 'https://downloads.example/setup.exe');
    expect(resolved.sourceName, 'DREAMMANGAREADER-SETUP.EXE');
    expect(resolved.sha256, checksum);
  });

  test('parses and binds schema 2 chunked assets', () {
    final manifest = UpdateManifest.fromJson(
      manifestJson(
        schemaVersion: 2,
        sizeBytes: 1536,
        parts: const [
          {
            'fileName': 'DreamMangaReader-setup.exe.part001',
            'sha256': checksum,
            'sizeBytes': 1024,
          },
          {
            'fileName': 'DreamMangaReader-setup.exe.part002',
            'sha256': checksum,
            'sizeBytes': 512,
          },
        ],
      ),
    );
    final resolved = manifest.resolve(
      UpdatePlatform.windows,
      const [
        RemoteAsset(
          name: 'DREAMMANGAREADER-SETUP.EXE.PART001',
          url: 'https://downloads.example/setup.part001',
          size: 1024,
        ),
        RemoteAsset(
          name: 'DreamMangaReader-setup.exe.part002',
          url: 'https://downloads.example/setup.part002',
          size: 512,
        ),
      ],
    ).single;

    expect(manifest.schemaVersion, 2);
    expect(manifest.assets.single.isChunked, isTrue);
    expect(resolved.isChunked, isTrue);
    expect(resolved.url, isNull);
    expect(
      resolved.parts.map((part) => part.url),
      [
        'https://downloads.example/setup.part001',
        'https://downloads.example/setup.part002',
      ],
    );
  });

  test('update sources expose display names and non-null fallbacks', () {
    expect(UpdateSource.gitee.displayName, 'Gitee');
    expect(UpdateSource.gitee.fallback, UpdateSource.github);
    expect(UpdateSource.github.displayName, 'GitHub');
    expect(UpdateSource.github.fallback, UpdateSource.gitee);
  });

  test('binds and validates every manifest asset for a platform', () {
    final json = manifestJson();
    (json['assets'] as List).add({
      'platform': 'windows',
      'arch': 'x64',
      'kind': 'portable',
      'fileName': 'DreamMangaReader-windows-x64.zip',
      'sha256': checksum,
      'sizeBytes': 2048,
    });
    final manifest = UpdateManifest.fromJson(json);

    final resolved = manifest.resolve(
      UpdatePlatform.windows,
      const [
        RemoteAsset(
          name: 'dreammangareader-setup.exe',
          url: 'https://downloads.example/setup.exe',
          size: 1024,
        ),
        RemoteAsset(
          name: 'DREAMMANGAREADER-WINDOWS-X64.ZIP',
          url: 'https://downloads.example/portable.zip',
          size: 2048,
        ),
      ],
    );

    expect(resolved, hasLength(2));
    expect(resolved.map((asset) => asset.kind), ['installer', 'portable']);
  });

  test('rejects a missing second manifest asset', () {
    final json = manifestJson();
    (json['assets'] as List).add({
      'platform': 'windows',
      'arch': 'x64',
      'kind': 'portable',
      'fileName': 'DreamMangaReader-windows-x64.zip',
      'sha256': checksum,
      'sizeBytes': 2048,
    });
    final manifest = UpdateManifest.fromJson(json);

    expect(
      () => manifest.resolve(
        UpdatePlatform.windows,
        const [
          RemoteAsset(
            name: 'DreamMangaReader-setup.exe',
            url: 'https://downloads.example/setup.exe',
            size: 1024,
          ),
        ],
      ),
      throwsFormatException,
    );
  });

  test('rejects traversal in asset file names', () {
    expect(
      () => UpdateManifest.fromJson(manifestJson(fileName: '../setup.exe')),
      throwsFormatException,
    );
  });

  test('rejects unsupported schema versions', () {
    expect(
      () => UpdateManifest.fromJson(manifestJson(schemaVersion: 3)),
      throwsFormatException,
    );
  });

  test('rejects parts in schema 1 manifests', () {
    expect(
      () => UpdateManifest.fromJson(
        manifestJson(
          sizeBytes: 1536,
          parts: const [
            {
              'fileName': 'DreamMangaReader-setup.exe.part001',
              'sha256': checksum,
              'sizeBytes': 1024,
            },
            {
              'fileName': 'DreamMangaReader-setup.exe.part002',
              'sha256': checksum,
              'sizeBytes': 512,
            },
          ],
        ),
      ),
      throwsFormatException,
    );
  });

  test('rejects chunk sizes that do not reconstruct the final asset', () {
    expect(
      () => UpdateManifest.fromJson(
        manifestJson(
          schemaVersion: 2,
          sizeBytes: 1537,
          parts: const [
            {
              'fileName': 'DreamMangaReader-setup.exe.part001',
              'sha256': checksum,
              'sizeBytes': 1024,
            },
            {
              'fileName': 'DreamMangaReader-setup.exe.part002',
              'sha256': checksum,
              'sizeBytes': 512,
            },
          ],
        ),
      ),
      throwsFormatException,
    );
  });

  test('rejects a missing remote chunk', () {
    final manifest = UpdateManifest.fromJson(
      manifestJson(
        schemaVersion: 2,
        sizeBytes: 1536,
        parts: const [
          {
            'fileName': 'DreamMangaReader-setup.exe.part001',
            'sha256': checksum,
            'sizeBytes': 1024,
          },
          {
            'fileName': 'DreamMangaReader-setup.exe.part002',
            'sha256': checksum,
            'sizeBytes': 512,
          },
        ],
      ),
    );

    expect(
      () => manifest.resolve(
        UpdatePlatform.windows,
        const [
          RemoteAsset(
            name: 'DreamMangaReader-setup.exe.part001',
            url: 'https://downloads.example/setup.part001',
            size: 1024,
          ),
        ],
      ),
      throwsFormatException,
    );
  });

  test('rejects another application id', () {
    expect(
      () => UpdateManifest.fromJson(manifestJson(appId: 'AnotherApp')),
      throwsFormatException,
    );
  });

  test('rejects invalid semantic versions', () {
    expect(
      () => UpdateManifest.fromJson(manifestJson(version: '1.2')),
      throwsFormatException,
    );
  });

  test('accepts SemVer prerelease identifiers outside release channels', () {
    final manifest = UpdateManifest.fromJson(
      manifestJson(version: '1.2.3-preview.7.sha-abc+build.5'),
    );
    expect(manifest.version, '1.2.3-preview.7.sha-abc+build.5');
  });

  test('rejects leading zeroes in SemVer numeric identifiers', () {
    for (final version in ['01.2.3', '1.02.3', '1.2.03', '1.2.3-preview.01']) {
      expect(
        () => UpdateManifest.fromJson(manifestJson(version: version)),
        throwsFormatException,
        reason: version,
      );
    }
  });

  test('rejects non-SHA-256 checksums', () {
    expect(
      () => UpdateManifest.fromJson(manifestJson(sha256: 'abc123')),
      throwsFormatException,
    );
  });

  test('rejects non-positive asset sizes', () {
    expect(
      () => UpdateManifest.fromJson(manifestJson(sizeBytes: 0)),
      throwsFormatException,
    );
  });

  test('rejects an asset absent from the remote release', () {
    final manifest = UpdateManifest.fromJson(manifestJson());

    expect(
      () => manifest.resolve(
        UpdatePlatform.windows,
        const [
          RemoteAsset(
            name: 'other-setup.exe',
            url: 'https://downloads.example/other-setup.exe',
            size: 1024,
          ),
        ],
      ),
      throwsFormatException,
    );
  });

  test('rejects an asset whose remote size does not match the manifest', () {
    final manifest = UpdateManifest.fromJson(manifestJson());

    expect(
      () => manifest.resolve(
        UpdatePlatform.windows,
        const [
          RemoteAsset(
            name: 'DreamMangaReader-setup.exe',
            url: 'https://downloads.example/setup.exe',
            size: 1025,
          ),
        ],
      ),
      throwsFormatException,
    );
  });
}
