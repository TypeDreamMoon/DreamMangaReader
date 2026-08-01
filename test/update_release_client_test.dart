import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:dream_manga_reader/core/update/update_release_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ResponseBody _octetStreamJson(int status, Object body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/octet-stream'],
      },
    );

Dio _stubDio(ResponseBody Function(RequestOptions options) handler) =>
    Dio()..httpClientAdapter = _StubAdapter(handler);

Map<String, Object> _manifest({int size = 12}) => {
      'schemaVersion': 1,
      'appId': 'DreamMangaReader',
      'version': '1.3.1',
      'channel': 'stable',
      'assets': [
        {
          'platform': 'android',
          'arch': 'universal',
          'kind': 'installer',
          'fileName': 'a.apk',
          'sha256': 'a' * 64,
          'sizeBytes': size,
        },
      ],
    };

void main() {
  test('parses GitHub release assets', () {
    final release = GitHubReleaseClient.parseRelease({
      'tag_name': 'v1.3.1',
      'html_url':
          'https://github.com/TypeDreamMoon/DreamMangaReader/releases/tag/v1.3.1',
      'body': 'notes',
      'draft': false,
      'prerelease': false,
      'assets': [
        {
          'name': 'a.apk',
          'size': 12,
          'browser_download_url': 'https://example/a.apk',
        },
      ],
    });

    expect(release.source, UpdateSource.github);
    expect(release.tag, 'v1.3.1');
    expect(release.assets.single.size, 12);
  });

  test('parses Gitee release plus attach files', () {
    final release = GiteeReleaseClient.parseRelease(
      {
        'id': 7,
        'tag_name': 'v1.3.1',
        'body': 'notes',
        'prerelease': false,
      },
      [
        {
          'name': 'a.apk',
          'size': 12,
          'browser_download_url': 'https://gitee.com/a.apk',
        },
      ],
    );

    expect(release.source, UpdateSource.gitee);
    expect(release.pageUrl, contains('/releases/tag/v1.3.1'));
    expect(release.assets.single.url, 'https://gitee.com/a.apk');
  });

  test('drops GitHub drafts and malformed assets', () {
    final releases = GitHubReleaseClient.parseReleaseList([
      {
        'tag_name': 'v9.0.0',
        'html_url': 'https://example/draft',
        'draft': true,
        'assets': [],
      },
      {
        'tag_name': 'v1.3.1',
        'html_url': 'https://example/release',
        'draft': false,
        'assets': [
          {'name': '', 'size': 0},
        ],
      },
    ]);

    expect(releases, hasLength(1));
    expect(releases.single.assets, isEmpty);
  });

  test('source exception retains source and HTTP status', () {
    const error = UpdateSourceException(
      UpdateSource.gitee,
      'request failed',
      statusCode: 503,
    );
    expect(error.source, UpdateSource.gitee);
    expect(error.statusCode, 503);
    expect(error.toString(), contains('Gitee'));
  });

  test('Gitee loads attachment files only for the selected release', () async {
    final requestedPaths = <String>[];
    final client = GiteeReleaseClient(
      dio: _stubDio((options) {
        requestedPaths.add(options.uri.path);
        if (options.uri.path.endsWith('/releases')) {
          expect(options.queryParameters['direction'], 'desc');
          return _json(200, [
            {
              'id': 7,
              'tag_name': 'v1.3.1',
              'body': 'notes',
              'prerelease': false,
            },
          ]);
        }
        return _json(200, [
          {
            'name': 'a.apk',
            'size': 12,
            'browser_download_url': 'https://gitee.com/a.apk',
          },
        ]);
      }),
    );

    final releases = await client.listReleases();
    expect(releases.single.assets, isEmpty);
    expect(requestedPaths, hasLength(1));

    final loaded = await client.loadAssets(releases.single);
    expect(loaded.assets.single.name, 'a.apk');
    expect(requestedPaths, hasLength(2));
    expect(requestedPaths.last, endsWith('/releases/7/attach_files'));
  });

  test('fetches and validates a manifest against its GitHub release', () async {
    final client = GitHubReleaseClient(
      dio: _stubDio((options) => _json(200, _manifest())),
    );
    final release = GitHubReleaseClient.parseRelease({
      'tag_name': 'v1.3.1',
      'html_url': 'https://example/release',
      'prerelease': false,
      'assets': [
        {
          'name': updateManifestAssetName,
          'size': 200,
          'browser_download_url': 'https://example/manifest.json',
        },
        {
          'name': 'a.apk',
          'size': 12,
          'browser_download_url': 'https://example/a.apk',
        },
      ],
    });

    final manifest = await client.fetchManifest(release);
    expect(manifest.version, '1.3.1');
  });

  test('decodes a manifest served as an octet stream', () async {
    final client = GitHubReleaseClient(
      dio: _stubDio((options) => _octetStreamJson(200, _manifest())),
    );
    final release = GitHubReleaseClient.parseRelease({
      'tag_name': 'v1.3.1',
      'html_url': 'https://example/release',
      'prerelease': false,
      'assets': [
        {
          'name': updateManifestAssetName,
          'size': 200,
          'browser_download_url': 'https://example/manifest.json',
        },
        {
          'name': 'a.apk',
          'size': 12,
          'browser_download_url': 'https://example/a.apk',
        },
      ],
    });

    final manifest = await client.fetchManifest(release);

    expect(manifest.version, '1.3.1');
  });

  test('rejects a manifest whose attachment size differs', () async {
    final client = GitHubReleaseClient(
      dio: _stubDio((options) => _json(200, _manifest(size: 13))),
    );
    final release = GitHubReleaseClient.parseRelease({
      'tag_name': 'v1.3.1',
      'html_url': 'https://example/release',
      'prerelease': false,
      'assets': [
        {
          'name': updateManifestAssetName,
          'size': 200,
          'browser_download_url': 'https://example/manifest.json',
        },
        {
          'name': 'a.apk',
          'size': 12,
          'browser_download_url': 'https://example/a.apk',
        },
      ],
    });

    await expectLater(
      client.fetchManifest(release),
      throwsA(
        isA<UpdateSourceException>()
            .having((error) => error.source, 'source', UpdateSource.github)
            .having((error) => error.message, 'message', contains('manifest')),
      ),
    );
  });
}
