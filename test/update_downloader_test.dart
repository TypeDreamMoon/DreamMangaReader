import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/update/update_downloader.dart';
import 'package:dream_manga_reader/core/update/update_models.dart';
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

ResolvedUpdateAsset _asset() => const ResolvedUpdateAsset(
      platform: UpdatePlatform.android,
      arch: 'arm64-v8a',
      kind: 'installer',
      fileName: 'package.bin',
      sha256:
          '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
      sizeBytes: 3,
      url: 'https://example/package.bin',
      sourceName: 'package.bin',
    );

String _hash(List<int> bytes) => sha256.convert(bytes).toString();

ResolvedUpdateAsset _chunkedAsset({String? finalSha256}) => ResolvedUpdateAsset(
      platform: UpdatePlatform.windows,
      arch: 'x64',
      kind: 'installer',
      fileName: 'package.bin',
      sha256: finalSha256 ?? _hash([1, 2, 3]),
      sizeBytes: 3,
      parts: [
        ResolvedUpdatePart(
          fileName: 'package.bin.part001',
          sha256: _hash([1, 2]),
          sizeBytes: 2,
          url: 'https://example/package.bin.part001',
          sourceName: 'package.bin.part001',
        ),
        ResolvedUpdatePart(
          fileName: 'package.bin.part002',
          sha256: _hash([3]),
          sizeBytes: 1,
          url: 'https://example/package.bin.part002',
          sourceName: 'package.bin.part002',
        ),
      ],
    );

const _cacheName =
    '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81-package.bin';

String? _rangeHeader(RequestOptions options) {
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() == 'range') return '${entry.value}';
  }
  return null;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dmr-downloader-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('accepts matching size and SHA-256', () async {
    final file = File('${temp.path}${Platform.pathSeparator}package.bin')
      ..writeAsBytesSync([1, 2, 3]);

    await UpdateFileVerifier.verify(
      file,
      expectedSize: 3,
      expectedSha256:
          '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
    );

    expect(file.existsSync(), isTrue);
  });

  test('deletes corrupt download', () async {
    final file = File('${temp.path}${Platform.pathSeparator}package.download')
      ..writeAsBytesSync([1, 2, 3]);

    await expectLater(
      UpdateFileVerifier.verify(
        file,
        expectedSize: 4,
        expectedSha256: '0' * 64,
      ),
      throwsA(isA<UpdateIntegrityException>()),
    );
    expect(file.existsSync(), isFalse);
  });

  test('206 response appends after the correct Range header', () async {
    final partial = File(
      '${temp.path}${Platform.pathSeparator}$_cacheName.download',
    )..writeAsBytesSync([1, 2]);
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((options) {
        expect(_rangeHeader(options), 'bytes=2-');
        return ResponseBody.fromBytes(
          [3],
          206,
          headers: {
            Headers.contentLengthHeader: ['1'],
            'content-range': ['bytes 2-2/3'],
          },
        );
      });

    final downloaded = await UpdateDownloader(
      dio: dio,
      cacheDirectory: temp,
    ).download(_asset());

    expect(partial.existsSync(), isFalse);
    expect(downloaded.readAsBytesSync(), [1, 2, 3]);
  });

  test('200 response to a resume attempt truncates and restarts', () async {
    File('${temp.path}${Platform.pathSeparator}$_cacheName.download')
        .writeAsBytesSync([9, 9]);
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((options) {
        expect(_rangeHeader(options), 'bytes=2-');
        return ResponseBody.fromBytes(
          [1, 2, 3],
          200,
          headers: {
            Headers.contentLengthHeader: ['3'],
          },
        );
      });

    final downloaded = await UpdateDownloader(
      dio: dio,
      cacheDirectory: temp,
    ).download(_asset());

    expect(downloaded.readAsBytesSync(), [1, 2, 3]);
  });

  test('replaces a corrupt completed cache entry without a manual retry',
      () async {
    final cached = File('${temp.path}${Platform.pathSeparator}$_cacheName')
      ..writeAsBytesSync([9, 9, 9]);
    var requests = 0;
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((options) {
        requests++;
        return ResponseBody.fromBytes(
          [1, 2, 3],
          200,
          headers: {
            Headers.contentLengthHeader: ['3'],
          },
        );
      });

    final downloaded = await UpdateDownloader(
      dio: dio,
      cacheDirectory: temp,
    ).download(_asset());

    expect(requests, 1);
    expect(downloaded.path, cached.path);
    expect(downloaded.readAsBytesSync(), [1, 2, 3]);
  });

  test('downloads, verifies and assembles chunked assets', () async {
    final requested = <String>[];
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((options) {
        requested.add(options.uri.path);
        final bytes = options.uri.path.endsWith('part001') ? [1, 2] : [3];
        return ResponseBody.fromBytes(
          bytes,
          200,
          headers: {
            Headers.contentLengthHeader: ['${bytes.length}'],
          },
        );
      });
    final progress = <double>[];

    final downloaded = await UpdateDownloader(
      dio: dio,
      cacheDirectory: temp,
    ).download(_chunkedAsset(), onProgress: progress.add);

    expect(requested, [
      '/package.bin.part001',
      '/package.bin.part002',
    ]);
    expect(downloaded.readAsBytesSync(), [1, 2, 3]);
    expect(progress.last, 1);
    expect(
      temp.listSync().whereType<File>().map((file) => file.path),
      everyElement(isNot(contains('.part00'))),
    );
  });

  test('reuses verified chunk cache without network requests', () async {
    final asset = _chunkedAsset();
    for (var index = 0; index < asset.parts.length; index++) {
      final part = asset.parts[index];
      File(
        '${temp.path}${Platform.pathSeparator}'
        '${part.sha256}-${part.fileName}',
      ).writeAsBytesSync(index == 0 ? [1, 2] : [3]);
    }
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((_) {
        fail('verified chunks should not be downloaded again');
      });

    final downloaded = await UpdateDownloader(
      dio: dio,
      cacheDirectory: temp,
    ).download(asset);

    expect(downloaded.readAsBytesSync(), [1, 2, 3]);
  });

  test('rejects an assembled file whose final checksum differs', () async {
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((options) {
        final bytes = options.uri.path.endsWith('part001') ? [1, 2] : [3];
        return ResponseBody.fromBytes(bytes, 200);
      });

    await expectLater(
      UpdateDownloader(dio: dio, cacheDirectory: temp).download(
        _chunkedAsset(finalSha256: 'f' * 64),
      ),
      throwsA(isA<UpdateIntegrityException>()),
    );
    expect(
      File('${temp.path}${Platform.pathSeparator}${'f' * 64}-package.bin')
          .existsSync(),
      isFalse,
    );
  });

  test('cache cleanup keeps newest two packages plus active paths', () async {
    final old = File('${temp.path}${Platform.pathSeparator}old.apk')
      ..writeAsBytesSync([1]);
    final middle = File('${temp.path}${Platform.pathSeparator}middle.apk')
      ..writeAsBytesSync([2]);
    final newest = File('${temp.path}${Platform.pathSeparator}newest.apk')
      ..writeAsBytesSync([3]);
    final now = DateTime.now();
    old.setLastModifiedSync(now.subtract(const Duration(minutes: 3)));
    middle.setLastModifiedSync(now.subtract(const Duration(minutes: 2)));
    newest.setLastModifiedSync(now.subtract(const Duration(minutes: 1)));

    await UpdateCacheCleaner.cleanup(temp, activePaths: {old.path});
    expect([old, middle, newest].every((file) => file.existsSync()), isTrue);

    await UpdateCacheCleaner.cleanup(temp, activePaths: const {});
    expect(old.existsSync(), isFalse);
    expect(middle.existsSync(), isTrue);
    expect(newest.existsSync(), isTrue);
  });
}
