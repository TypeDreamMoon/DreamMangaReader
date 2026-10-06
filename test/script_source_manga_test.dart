import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/source.dart';

void main() {
  /// 回归 E3:`ScriptSource` 的构造函数就 eval 脚本,坏脚本会从构造里抛出来。
  /// 引擎是构造前建好、由外部传进来的,抛出时还没有人持有它 —— 旧代码于是每探测
  /// 一次坏源就漏一个 QuickJS 运行时。
  group('a script that fails to load', () {
    test('disposes the engine it was handed', () {
      final engine = _FakeEngine(failOn: 'boom');
      expect(
        () => ScriptSource(
          engine: engine,
          http: _NoHttp(),
          scriptCode: 'boom',
        ),
        throwsA(isA<JsEngineException>()),
      );
      expect(engine.disposeCount, 1, reason: '构造失败必须回收引擎');
    });

    test('disposes the engine when __source.meta is missing', () {
      final engine = _FakeEngine(metaJson: 'null');
      expect(
        () => ScriptSource(
          engine: engine,
          http: _NoHttp(),
          scriptCode: 'var __source = {};',
        ),
        throwsA(anything),
      );
      expect(engine.disposeCount, 1);
    });

    test('a successful load keeps the engine alive until dispose', () {
      final engine = _FakeEngine();
      final source = ScriptSource(
        engine: engine,
        http: _NoHttp(),
        scriptCode: 'var __source = {};',
      );
      expect(engine.disposeCount, 0);
      expect(source.id, 'fake');
      source.dispose();
      expect(engine.disposeCount, 1);
    });
  });

  /// 回归 E5:JS 里没有 int/String 之分,源脚本把 `id` 写成数字、`index` 写成
  /// 字符串都很常见。旧代码用裸 `as int` / `as String`,一条记录类型不对就以
  /// 一句看不出字段名的 TypeError 崩掉整章 / 整页搜索结果。
  group('loose script values', () {
    ScriptSource sourceWith(Map<String, String> handlers) => ScriptSource(
          engine: _FakeEngine(handlers: handlers),
          http: _EchoHttp(),
          scriptCode: 'var __source = {};',
        );

    test('a numeric page index and a numeric id still parse', () async {
      final source = sourceWith({
        'handleChapter': '[{"index":"1","url":"https://e.test/b.png"},'
            '{"index":0,"url":"https://e.test/a.png"}]',
      });
      final pages = await source.getPages('m', 'c');
      expect(pages.map((p) => p.index), [0, 1]);
      expect(pages.first.url, 'https://e.test/a.png');
      source.dispose();
    });

    test('a numeric manga id becomes a string', () async {
      final source = sourceWith({
        'handleSearch': '[{"id":12345,"title":"数字 id","updatedAt":"1700000000"}]',
      });
      final page = await source.getSearch('q', 1);
      expect(page.items.single.id, '12345');
      expect(page.items.single.updatedAt, 1700000000);
      source.dispose();
    });

    test('a numeric chapter id and a string chapter number parse', () async {
      final source = sourceWith({
        'handleChapterList': '[{"id":7,"name":"第7话","number":"7.5"}]',
      });
      final page = await source.getChapters('m');
      expect(page.items.single.id, '7');
      expect(page.items.single.number, 7.5);
      source.dispose();
    });

    test('non-string entries in authors are coerced, not fatal', () async {
      final source = sourceWith({
        'handleSearch': '[{"id":"a","title":"t","authors":["甲",2,null]}]',
      });
      final page = await source.getSearch('q', 1);
      expect(page.items.single.authors, ['甲', '2']);
      source.dispose();
    });

    test('a missing required field names the field it could not read',
        () async {
      final source = sourceWith({
        'handleChapter': '[{"url":"https://e.test/a.png"}]',
      });
      await expectLater(
        source.getPages('m', 'c'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('index'))),
      );
      source.dispose();
    });

    test('a record that is not an object is reported, not a TypeError',
        () async {
      final source = sourceWith({'handleSearch': '["not an object"]'});
      await expectLater(
        source.getSearch('q', 1),
        throwsA(isA<FormatException>()),
      );
      source.dispose();
    });
  });

  /// 回归 E12:`getChapters` 无条件返回 `Paged(hasNext: false)`,于是
  /// `prepareChapterList(mangaId, page)` 的 page 参数全链路不可达 —— 分页的源
  /// 只能拿到第一页目录,长篇被截断。
  group('chapter list pagination', () {
    ScriptSource sourceWith(Map<String, String> handlers) => ScriptSource(
          engine: _FakeEngine(handlers: handlers),
          http: _EchoHttp(),
          scriptCode: 'var __source = {};',
        );

    test('a bare array still means "no more pages"', () async {
      final source = sourceWith({
        'handleChapterList': '[{"id":"c1","name":"第1话"}]',
      });
      final page = await source.getChapters('m');
      expect(page.items.single.id, 'c1');
      expect(page.hasNext, isFalse);
      source.dispose();
    });

    test('{chapters, hasNext} propagates the flag', () async {
      final source = sourceWith({
        'handleChapterList':
            '{"chapters":[{"id":"c1","name":"第1话"}],"hasNext":true}',
      });
      final page = await source.getChapters('m');
      expect(page.items.single.id, 'c1');
      expect(page.hasNext, isTrue, reason: '脚本表态还有下一页,必须透传');
      source.dispose();
    });

    test('{chapters, hasNext:false} ends the walk', () async {
      final source = sourceWith({
        'handleChapterList':
            '{"chapters":[{"id":"c1","name":"第1话"}],"hasNext":false}',
      });
      expect((await source.getChapters('m')).hasNext, isFalse);
      source.dispose();
    });

    test('the existing {items, next} continuation envelope still works',
        () async {
      final source = sourceWith({
        'handleChapterList': '{"items":[{"id":"c1","name":"第1话"}]}',
      });
      final page = await source.getChapters('m');
      expect(page.items.single.id, 'c1');
      expect(page.hasNext, isFalse);
      source.dispose();
    });

    test('a malformed envelope names the expected key', () async {
      final source = sourceWith({'handleChapterList': '{"nope":1}'});
      await expectLater(
        source.getChapters('m'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('chapters'))),
      );
      source.dispose();
    });
  });
}

/// 不碰原生 QuickJS 的假引擎:按 `__source.<fn>` 的函数名回放事先写好的 JSON,
/// 于是 prepare→fetch→handle 的整条链路可以在纯 Dart 单测里跑完。
class _FakeEngine implements JsEngine {
  _FakeEngine({
    this.failOn,
    this.metaJson = '{"id":"fake","name":"Fake"}',
    Map<String, String>? handlers,
  }) : handlers = handlers ?? const {};

  /// eval 到含这段文本的代码就抛(模拟脚本语法错 / 运行时抛出)。
  final String? failOn;
  final String metaJson;

  /// `handleXxx` / `prepareXxx` → 该调用返回的 JSON 文本。
  final Map<String, String> handlers;
  int disposeCount = 0;

  @override
  String evalSync(String code) {
    final boom = failOn;
    if (boom != null && code.contains(boom)) {
      throw JsEngineException('SyntaxError: unexpected token');
    }
    if (code.contains('__source.meta')) return metaJson;
    if (code.contains('__source.filters')) return 'null';
    if (code.contains('__source.sections')) return 'null';
    for (final entry in handlers.entries) {
      if (code.contains('__source.${entry.key}(')) return entry.value;
    }
    // 没显式给的 prepare* 一律回一个最小请求描述,好让 _run 走到 handle*。
    if (code.contains('__source.prepare')) {
      return '{"url":"https://example.test/"}';
    }
    return '';
  }

  @override
  void onMessage(String channel, dynamic Function(dynamic message) handler) {}

  @override
  void dispose() => disposeCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoHttp implements HttpService {
  @override
  Future<HostResponse> fetch(HostRequest request) =>
      throw UnimplementedError('fetch');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 每次请求都回同一段(空)响应体 —— 解析结果全由假引擎的 handler 决定。
class _EchoHttp implements HttpService {
  @override
  Future<HostResponse> fetch(HostRequest request) async =>
      const HostResponse(status: 200, headers: {}, body: '');
}
