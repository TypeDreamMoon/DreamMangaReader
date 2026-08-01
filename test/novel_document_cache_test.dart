import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/novel_document_cache.dart';
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

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('novel-cache-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('cache commits only complete documents and rewrites resources',
      () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((options) {
        requests.add(options);
        return ResponseBody.fromBytes(
          utf8.encode('image:${options.uri.path}'),
          200,
          headers: {
            Headers.contentTypeHeader: ['image/png'],
          },
        );
      });
    final cache = NovelDocumentCache(root: temp.path, dio: dio);
    final document = NovelDocument(
      format: NovelDocumentFormat.html,
      content: '<p>正文<img src="images/a.png"></p>',
      baseUrl: 'https://example.test/book/chapter/',
      resources: const {
        'images/a.png': 'https://cdn.example.test/a.png',
        'images/b.png': 'https://cdn.example.test/b.png',
      },
    );

    final saved = await cache.save(
      'source',
      'novel',
      'chapter',
      document,
      headers: const {'Referer': 'https://example.test/'},
    );
    final restored = await cache.read('source', 'novel', 'chapter');

    expect(restored, isNotNull);
    expect(restored!.directory, saved.directory);
    expect(restored.resourceCount, 2);
    expect(restored.byteCount, greaterThan(0));
    expect(restored.html, contains('resources/'));
    expect(restored.html, isNot(contains('https://cdn.example.test')));
    expect(
      requests.every(
        (request) => request.headers['Referer'] == 'https://example.test/',
      ),
      isTrue,
    );
    expect(
      Directory(temp.path)
          .listSync(recursive: true)
          .whereType<Directory>()
          .any((entry) => entry.path.contains('.partial')),
      isFalse,
    );
  });

  test('failed resource download never publishes a completed index', () async {
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter(
        (_) => ResponseBody.fromString('failure', 503),
      );
    final cache = NovelDocumentCache(root: temp.path, dio: dio);
    final document = NovelDocument(
      format: NovelDocumentFormat.html,
      content: '<p><img src="a.png"></p>',
      baseUrl: 'https://example.test/chapter/',
      resources: const {'a.png': 'https://example.test/a.png'},
    );

    await expectLater(
      cache.save('source', 'novel', 'chapter', document),
      throwsException,
    );

    expect(await cache.read('source', 'novel', 'chapter'), isNull);
    expect(
      Directory(temp.path)
          .listSync(recursive: true)
          .whereType<File>()
          .any((entry) => entry.path.endsWith('metadata.json')),
      isFalse,
    );
  });

  test('remote images in sanitized HTML are cached without a resource map',
      () async {
    var requests = 0;
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((_) {
        requests++;
        return ResponseBody.fromBytes([1, 2, 3], 200);
      });
    final cache = NovelDocumentCache(root: temp.path, dio: dio);
    final document = NovelDocument(
      format: NovelDocumentFormat.html,
      content: '<p><img src="https://cdn.example.test/inline.png"></p>',
    );

    final saved = await cache.save('source', 'novel', 'inline', document);

    expect(requests, 1);
    expect(saved.resourceCount, 1);
    expect(saved.html, contains('resources/'));
    expect(saved.html, isNot(contains('https://cdn.example.test')));
  });

  test('untrusted identity components cannot escape the cache root', () async {
    final cache = NovelDocumentCache(root: temp.path, dio: Dio());
    final document = NovelDocument(
      format: NovelDocumentFormat.text,
      content: '纯文本章节',
    );

    final saved = await cache.save('..', r'..\outside', '../chapter', document);
    final root = temp.absolute.path.toLowerCase();

    expect(saved.directory.toLowerCase().startsWith(root), isTrue);
    expect(await cache.read('..', r'..\outside', '../chapter'), isNotNull);
    expect(
        File('${temp.parent.path}${Platform.pathSeparator}outside')
            .existsSync(),
        isFalse);
  });
}
