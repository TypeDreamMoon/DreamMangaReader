import 'dart:convert';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:flutter_test/flutter_test.dart';

class RoutingHttp implements HttpService {
  RoutingHttp(this.respond);

  final HostResponse Function(HostRequest request) respond;
  final requests = <HostRequest>[];

  @override
  Future<HostResponse> fetch(HostRequest request) async {
    requests.add(request);
    return respond(request);
  }
}

HostResponse jsonResponse(Object body) => HostResponse(
      status: 200,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body),
    );

const legacyScript = r'''
var __source = {
  meta: { id: 'legacy', name: 'Legacy', baseUrl: 'https://example.test' },
  prepareChapterList: function () {
    return { url: 'https://example.test/legacy' };
  },
  handleChapterList: function () {
    return [{ id: 'c1', name: '第一话', number: 1 }];
  }
};
''';

const capabilityScript = r'''
var __source = {
  meta: { id: 'capability', name: 'Capability', baseUrl: 'https://example.test' },
  prepareChapterList: function () {
    if (!globalThis.__sourceCapabilities ||
        globalThis.__sourceCapabilities.collectionContinuation !== 1) {
      throw new Error('collection continuation capability unavailable');
    }
    return { url: 'https://example.test/capability' };
  },
  handleChapterList: function () {
    return [{ id: 'c1', name: '第一话', number: 1 }];
  }
};
''';

const continuationScript = r'''
var __source = {
  meta: { id: 'paging', name: 'Paging', baseUrl: 'https://example.test' },
  prepareChapterList: function () {
    return { url: 'https://example.test/eps?page=1' };
  },
  handleChapterList: function (text) {
    var data = JSON.parse(text);
    return {
      items: data.items,
      next: data.page < data.pages
        ? { url: 'https://example.test/eps?page=' + (data.page + 1) }
        : null
    };
  },
  prepareChapter: function () {
    return { url: 'https://example.test/pages?page=1' };
  },
  handleChapter: function (text) {
    var data = JSON.parse(text);
    return {
      items: data.items,
      next: data.page < data.pages
        ? { url: 'https://example.test/pages?page=' + (data.page + 1) }
        : null
    };
  }
};
''';

const guardScript = r'''
var __source = {
  meta: { id: 'guards', name: 'Guards', baseUrl: 'https://example.test' },
  prepareChapterList: function (mangaId) {
    return { url: 'https://example.test/' + mangaId + '?page=1' };
  },
  handleChapterList: function (text) {
    return JSON.parse(text);
  }
};
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('source context exposes versioned collection continuation capability',
      () async {
    final source = ScriptSource(
      engine: JsEngine(),
      http: RoutingHttp((_) => jsonResponse({'unused': true})),
      scriptCode: capabilityScript,
    );
    addTearDown(source.dispose);

    final result = await source.getChapters('m1');

    expect(result.items.map((item) => item.id), ['c1']);
  });

  test('legacy chapter arrays still execute one request', () async {
    final http = RoutingHttp((_) => jsonResponse({'unused': true}));
    final source = ScriptSource(
      engine: JsEngine(),
      http: http,
      scriptCode: legacyScript,
    );
    addTearDown(source.dispose);

    final result = await source.getChapters('m1');

    expect(result.items.map((item) => item.id), ['c1']);
    expect(http.requests, hasLength(1));
  });

  test('chapter continuation merges every response in source order', () async {
    final http = RoutingHttp((request) {
      final page = Uri.parse(request.url).queryParameters['page'];
      return page == '1'
          ? jsonResponse({
              'page': 1,
              'pages': 2,
              'items': [
                {'id': 'c1', 'name': '第一话', 'number': 1},
                {'id': 'c2', 'name': '第二话', 'number': 2},
              ],
            })
          : jsonResponse({
              'page': 2,
              'pages': 2,
              'items': [
                {'id': 'c2', 'name': '重复第二话', 'number': 2},
                {'id': 'c3', 'name': '第三话', 'number': 3},
              ],
            });
    });
    final source = ScriptSource(
      engine: JsEngine(),
      http: http,
      scriptCode: continuationScript,
    );
    addTearDown(source.dispose);

    final result = await source.getChapters('m1');

    expect(result.items.map((item) => item.id), ['c1', 'c2', 'c3']);
    expect(http.requests.map((request) => request.url), [
      'https://example.test/eps?page=1',
      'https://example.test/eps?page=2',
    ]);
  });

  test('image continuation sorts by index and keeps first duplicate', () async {
    final http = RoutingHttp((request) {
      final page = Uri.parse(request.url).queryParameters['page'];
      return page == '1'
          ? jsonResponse({
              'page': 1,
              'pages': 2,
              'items': [
                {'index': 1, 'url': 'https://img.test/first-1.jpg'},
                {'index': 0, 'url': 'https://img.test/0.jpg'},
              ],
            })
          : jsonResponse({
              'page': 2,
              'pages': 2,
              'items': [
                {'index': 1, 'url': 'https://img.test/repeated-1.jpg'},
                {'index': 2, 'url': 'https://img.test/2.jpg'},
              ],
            });
    });
    final source = ScriptSource(
      engine: JsEngine(),
      http: http,
      scriptCode: continuationScript,
    );
    addTearDown(source.dispose);

    final result = await source.getPages('m1', '1');

    expect(result.map((item) => item.index), [0, 1, 2]);
    expect(result[1].url, 'https://img.test/first-1.jpg');
  });

  test('duplicate continuation request stops before a second fetch', () async {
    var calls = 0;
    final http = RoutingHttp((request) {
      calls++;
      if (calls > 2) throw Exception('fixture stopped duplicate loop');
      return jsonResponse({
        'items': const [],
        'next': {'url': request.url},
      });
    });
    final source = ScriptSource(
      engine: JsEngine(),
      http: http,
      scriptCode: guardScript,
    );
    addTearDown(source.dispose);

    await expectLater(
      source.getChapters('duplicate'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('重复'),
        ),
      ),
    );
    expect(http.requests, hasLength(1));
  });

  test('malformed next value reports a source protocol error', () async {
    final http = RoutingHttp(
      (_) => jsonResponse({'items': const [], 'next': 'not-a-request'}),
    );
    final source = ScriptSource(
      engine: JsEngine(),
      http: http,
      scriptCode: guardScript,
    );
    addTearDown(source.dispose);

    await expectLater(
      source.getChapters('malformed'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('next'),
        ),
      ),
    );
  });

  test('malformed continuation envelope reports a source protocol error',
      () async {
    final http = RoutingHttp((_) => jsonResponse({'unexpected': true}));
    final source = ScriptSource(
      engine: JsEngine(),
      http: http,
      scriptCode: guardScript,
    );
    addTearDown(source.dispose);

    await expectLater(
      source.getChapters('malformed-envelope'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('items'),
        ),
      ),
    );
  });

  test('continuation request count is limited to one hundred', () async {
    var calls = 0;
    final http = RoutingHttp((_) {
      calls++;
      if (calls > 100) throw Exception('fixture exceeded one hundred calls');
      return jsonResponse({
        'items': const [],
        'next': {'url': 'https://example.test/endless?page=${calls + 1}'},
      });
    });
    final source = ScriptSource(
      engine: JsEngine(),
      http: http,
      scriptCode: guardScript,
    );
    addTearDown(source.dispose);

    await expectLater(
      source.getChapters('endless'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('100'),
        ),
      ),
    );
    expect(http.requests, hasLength(100));
  });

  test('a failed second page does not return partial chapters', () async {
    var calls = 0;
    final http = RoutingHttp((_) {
      calls++;
      if (calls == 2) throw Exception('page 2 unavailable');
      return jsonResponse({
        'items': [
          {'id': 'c1', 'name': '第一话'},
        ],
        'next': {'url': 'https://example.test/failure?page=2'},
      });
    });
    final source = ScriptSource(
      engine: JsEngine(),
      http: http,
      scriptCode: guardScript,
    );
    addTearDown(source.dispose);

    await expectLater(
      source.getChapters('failure'),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          allOf(contains('已完成 1 页'), contains('page 2 unavailable')),
        ),
      ),
    );
    expect(http.requests, hasLength(2));
  });
}
