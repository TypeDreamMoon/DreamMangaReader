import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/translate/translator.dart';

/// 回归 E-cache:翻译既没有缓存也没有限速。详情页每开一本书就把书名翻成 3~4 种
/// 语言,返回再进来又翻一遍 —— 同一个词一天能打几十次免费端点,并发还会整片超时。
void main() {
  setUp(clearTranslationCache);
  tearDown(clearTranslationCache);

  test('the same text and target is translated once', () async {
    final inner = _CountingTranslator();
    final tr = Translator.cached(inner);

    expect(await tr.translate('海贼王', TranslateLang.ja), '海贼王/ja#1');
    expect(await tr.translate('海贼王', TranslateLang.ja), '海贼王/ja#1');
    expect(await tr.translate('海贼王', TranslateLang.ja), '海贼王/ja#1');

    expect(inner.calls, 1);
  });

  test('a different target language is a different entry', () async {
    final inner = _CountingTranslator();
    final tr = Translator.cached(inner);

    await tr.translate('海贼王', TranslateLang.ja);
    await tr.translate('海贼王', TranslateLang.en);

    expect(inner.calls, 2);
  });

  test('a different provider scope does not reuse the entry', () async {
    final inner = _CountingTranslator();

    await Translator.cached(inner, scope: 'google').translate(
        '海贼王', TranslateLang.ja);
    await Translator.cached(inner, scope: 'llm').translate(
        '海贼王', TranslateLang.ja);

    expect(inner.calls, 2, reason: '换了服务商不能拿旧译文冒充');
  });

  test('concurrent requests for the same text share one translation',
      () async {
    final inner = _CountingTranslator(manual: true);
    final tr = Translator.cached(inner);

    final all = Future.wait([
      tr.translate('海贼王', TranslateLang.ja),
      tr.translate('海贼王', TranslateLang.ja),
      tr.translate('海贼王', TranslateLang.ja),
    ]);
    await pumpEventQueue();
    expect(inner.calls, 1, reason: '同一个词的并发只该发一次');

    inner.releaseAll();
    expect(await all, ['海贼王/ja#1', '海贼王/ja#1', '海贼王/ja#1']);
  });

  test('no more than four translations are in flight at once', () async {
    final inner = _CountingTranslator(manual: true);
    final tr = Translator.cached(inner);

    final all = Future.wait([
      for (var i = 0; i < 10; i++) tr.translate('书$i', TranslateLang.ja),
    ]);
    await pumpEventQueue();
    expect(inner.calls, 4, reason: '并发闸压在 4 条在途');

    inner.releaseAll();
    await pumpEventQueue();
    expect(inner.calls, 8, reason: '放行一批后才轮到后面的');

    inner.releaseAll();
    await pumpEventQueue();
    inner.releaseAll();
    expect(await all, hasLength(10));
    expect(inner.calls, 10);
  });

  test('a failure is not cached, so the next attempt retries', () async {
    final inner = _CountingTranslator(failFirst: true);
    final tr = Translator.cached(inner);

    await expectLater(
        tr.translate('海贼王', TranslateLang.ja), throwsA(isA<Exception>()));
    expect(await tr.translate('海贼王', TranslateLang.ja), '海贼王/ja#2');
    expect(inner.calls, 2);
  });

  test('a failure releases its slot in the concurrency gate', () async {
    final inner = _CountingTranslator(failAlways: true);
    final tr = Translator.cached(inner);

    for (var i = 0; i < 8; i++) {
      await expectLater(
          tr.translate('书$i', TranslateLang.ja), throwsA(isA<Exception>()));
    }
    expect(inner.calls, 8, reason: '失败也要放开闸门,不能把后续请求饿死');
  });
}

class _CountingTranslator implements Translator {
  _CountingTranslator({
    this.manual = false,
    this.failFirst = false,
    this.failAlways = false,
  });

  /// true = 每次调用挂起,等 [releaseAll] 才返回(用来观察在途条数)。
  final bool manual;
  final bool failFirst;
  final bool failAlways;

  int calls = 0;
  final List<Completer<String>> _pending = [];

  void releaseAll() {
    final pending = List.of(_pending);
    _pending.clear();
    for (final c in pending) {
      c.complete('released');
    }
  }

  @override
  Future<String> translate(String text, TranslateLang target) async {
    calls++;
    if (failAlways || (failFirst && calls == 1)) {
      throw Exception('boom');
    }
    final answer = '$text/${target.name}#$calls';
    if (!manual) return answer;
    final gate = Completer<String>();
    _pending.add(gate);
    await gate.future;
    return answer;
  }
}
