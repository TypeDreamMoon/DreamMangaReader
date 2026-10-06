import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/detail/chapter_merge.dart';

void main() {
  ChapterSource src(String id, List<String> names) => ChapterSource(
        SourceMeta(id: id, name: id, script: ''),
        _NoSource(),
        'm',
        [for (final n in names) Chapter(id: '$id:$n', name: n)],
      );

  List<String> labels(List<MergedChapter> rows) =>
      [for (final r in rows) r.label];

  test('extras land after the current source chapter just below them', () {
    final merged = mergeChapters(
      src('cur', ['第1话', '第3话']),
      [src('other', ['第1话', '第2话', '第3话', '第4话'])],
    );
    expect(labels(merged), ['第1话', '第2话', '第3话', '第4话']);
  });

  test('an unnumbered opener keeps the extras behind it', () {
    // 「序章」跟着前一话走:补充话不该挤到它前面去。
    final merged = mergeChapters(
      src('cur', ['序章', '第2话']),
      [src('other', ['第1话', '第2话'])],
    );
    expect(labels(merged), ['序章', '第1话', '第2话']);
  });

  test('an unnumbered tail is not pushed aside by a newer extra', () {
    // 「番外」在表尾:他源的新话接在它之后,而不是把它顶开。
    final merged = mergeChapters(
      src('cur', ['第1话', '番外']),
      [src('other', ['第1话', '第2话'])],
    );
    expect(labels(merged), ['第1话', '番外', '第2话']);
  });

  /// 回归 E13:`settle` 的兜底值是 `rows.length - 1`,当前源一话都没解析出话数时
  /// 这个值会一路传到 `settle[0]`,补充话于是被甩到**表尾**,和本函数文档说的
  /// 「当前源没有更小的 → 排到最前」正好相反。
  test('extras go to the front when the current source has no parsable numbers',
      () {
    final merged = mergeChapters(
      src('cur', ['序章', '番外', '特别篇']),
      [src('other', ['第1话', '第2话'])],
    );
    expect(labels(merged), ['第1话', '第2话', '序章', '番外', '特别篇'],
        reason: '没有锚点时补充话按话数升序自成一表,排在当前源的无号章之前');
  });

  test('a single unnumbered chapter still puts the extras first', () {
    final merged = mergeChapters(
      src('cur', ['番外']),
      [src('other', ['第7话'])],
    );
    expect(labels(merged), ['第7话', '番外']);
  });

  test('an empty current source keeps the extras in ascending order', () {
    final merged = mergeChapters(
      src('cur', const []),
      [src('other', ['第2话', '第1话'])],
    );
    expect(labels(merged), ['第1话', '第2话']);
  });

  test('a matched chapter records both providers instead of duplicating', () {
    final merged = mergeChapters(
      src('cur', ['第1话']),
      [src('other', ['第1话'])],
    );
    expect(labels(merged), ['第1话']);
    expect(merged.single.providers.map((p) => p.meta.id), ['cur', 'other']);
  });
}

class _NoSource implements MangaSource {
  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
