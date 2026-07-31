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
    );

    expect(resolved.url, 'https://downloads.example/setup.exe');
    expect(resolved.sourceName, 'DREAMMANGAREADER-SETUP.EXE');
    expect(resolved.sha256, checksum);
  });

  test('rejects traversal in asset file names', () {
    expect(
      () => UpdateManifest.fromJson(manifestJson(fileName: '../setup.exe')),
      throwsFormatException,
    );
  });

  test('rejects unsupported schema versions', () {
    expect(
      () => UpdateManifest.fromJson(manifestJson(schemaVersion: 2)),
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
