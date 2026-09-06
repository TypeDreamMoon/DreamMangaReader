import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/novel_document_cache.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

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

  test('one failed resource never costs the whole chapter', () async {
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((options) {
        if (options.uri.path.endsWith('bad.png')) {
          return ResponseBody.fromString('failure', 503);
        }
        return ResponseBody.fromBytes([1, 2, 3], 200);
      });
    final cache = NovelDocumentCache(root: temp.path, dio: dio);
    final document = NovelDocument(
      format: NovelDocumentFormat.html,
      content: '<p>正文<img src="good.png"><img src="bad.png"></p>',
      baseUrl: 'https://example.test/chapter/',
    );

    final saved = await cache.save('source', 'novel', 'chapter', document);
    final restored = await cache.read('source', 'novel', 'chapter');

    expect(saved.resourceCount, 1);
    expect(saved.missingResourceCount, 1);
    expect(saved.html, contains('正文'));
    expect(saved.html, contains('resources/'));
    // 失败的那张留着远程地址当占位,不再拖垮整章。
    expect(saved.html, contains('https://example.test/chapter/bad.png'));
    expect(restored, isNotNull);
    expect(restored!.missingResourceCount, 1);
  });

  test('chapter resources are fetched with bounded concurrency', () async {
    var active = 0;
    var peak = 0;
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((_) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return ResponseBody.fromBytes([1, 2, 3], 200);
      });
    final cache = NovelDocumentCache(
      root: temp.path,
      dio: dio,
      resourceConcurrency: 3,
    );
    final document = NovelDocument(
      format: NovelDocumentFormat.html,
      content: [
        for (var index = 0; index < 9; index++)
          '<p><img src="https://cdn.example.test/$index.png"></p>',
      ].join(),
    );

    final saved = await cache.save('source', 'novel', 'many', document);

    expect(saved.resourceCount, 9);
    expect(saved.missingResourceCount, 0);
    expect(peak, greaterThan(1));
    expect(peak, lessThanOrEqualTo(3));
  });

  test('a resource that never answers times out on its own', () async {
    final stalled = Completer<ResponseBody>();
    addTearDown(() {
      if (!stalled.isCompleted) {
        stalled.complete(ResponseBody.fromBytes(const [], 200));
      }
    });
    final dio = Dio()
      ..httpClientAdapter = _StubAdapter((options) {
        if (options.uri.path.endsWith('slow.png')) return stalled.future;
        return ResponseBody.fromBytes([1, 2, 3], 200);
      });
    final cache = NovelDocumentCache(
      root: temp.path,
      dio: dio,
      resourceTimeout: const Duration(milliseconds: 30),
    );
    final document = NovelDocument(
      format: NovelDocumentFormat.html,
      content: '<p>正文<img src="https://cdn.example.test/slow.png">'
          '<img src="https://cdn.example.test/quick.png"></p>',
    );

    final saved = await cache.save('source', 'novel', 'slow', document);

    expect(saved.resourceCount, 1);
    expect(saved.missingResourceCount, 1);
    expect(saved.html, contains('https://cdn.example.test/slow.png'));
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

  test('stat validates a chapter without decoding its body', () async {
    final cache = NovelDocumentCache(root: temp.path, dio: Dio());
    final saved = await cache.save(
      'source',
      'novel',
      'chapter',
      NovelDocument(
        format: NovelDocumentFormat.html,
        content: '<p>正文</p>',
      ),
    );
    // 长度不变、内容不再是合法 UTF-8:只看大小的体检通过,真读正文会炸。
    final document = File(saved.documentPath);
    final length = await document.length();
    await document.writeAsBytes(
      List<int>.filled(length, 0xff),
      flush: true,
    );

    final stat = await cache.stat('source', 'novel', 'chapter');

    expect(stat, isNotNull);
    expect(stat!.resourceCount, 0);
    expect(stat.byteCount, saved.byteCount);
    expect(await cache.read('source', 'novel', 'chapter'), isNull);
  });

  test('carriage return only text still breaks into paragraphs', () async {
    final cache = NovelDocumentCache(root: temp.path, dio: Dio());
    final document = NovelDocument(
      format: NovelDocumentFormat.text,
      content: '第一段\r第二段\r\r第四段\r\n第五段\n第六段',
    );

    final saved = await cache.save('source', 'novel', 'cr', document);

    expect(saved.html, contains('>第一段</p>'));
    expect(saved.html, contains('>第二段</p>'));
    expect(saved.html, contains('>第四段</p>'));
    expect(saved.html, contains('>第五段</p>'));
    expect(saved.html, contains('>第六段</p>'));
    expect('</p>'.allMatches(saved.html).length, 6);
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
