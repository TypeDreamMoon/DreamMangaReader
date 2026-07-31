import 'dart:io';
import 'dart:typed_data';

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
      '${temp.path}${Platform.pathSeparator}package.bin.download',
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
    File('${temp.path}${Platform.pathSeparator}package.bin.download')
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
