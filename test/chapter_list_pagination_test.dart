import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';

/// 回归 E12:`getChapters` 恒 `Paged(hasNext: false)`,`page` 参数全链路不可达,
/// 分页的源只能拿到第一页目录。详情页和更新扫描现在共用 [fetchAllChapters]
/// 逐页拉全 —— 两处走法必须一致,否则更新扫描会把详情页多出来的话当成新话。
void main() {
  test('a source that reports no next page is fetched once', () async {
    final source = _PagedSource(pages: [
      ['a', 'b'],
    ]);
    expect((await fetchAllChapters(source, 'm')).map((c) => c.id), ['a', 'b']);
    expect(source.requestedPages, [null]);
  });

  test('every page is pulled while the source says there is a next one',
      () async {
    final source = _PagedSource(pages: [
      ['a', 'b'],
      ['c', 'd'],
      ['e'],
    ]);
    final chapters = await fetchAllChapters(source, 'm');
    expect(chapters.map((c) => c.id), ['a', 'b', 'c', 'd', 'e']);
    expect(source.requestedPages, [null, 2, 3]);
  });

  test('duplicate chapters across pages are folded', () async {
    final source = _PagedSource(pages: [
      ['a', 'b'],
      ['b', 'c'],
    ]);
    expect((await fetchAllChapters(source, 'm')).map((c) => c.id),
        ['a', 'b', 'c']);
  });

  test('a source that ignores the page argument stops instead of looping',
      () async {
    // hasNext 恒真 + 每页都回同一批话 = 源根本没实现分页。必须停,而不是打满 30 次。
    final source = _PagedSource.repeating(['a', 'b']);
    expect((await fetchAllChapters(source, 'm')).map((c) => c.id), ['a', 'b']);
    expect(source.requestedPages, [null, 2]);
  });

  test('an always-hasNext source is capped', () async {
    // 每页都是新话且 hasNext 恒真 —— 只有上限能停下来。
    final source = _PagedSource.endless();
    final chapters = await fetchAllChapters(source, 'm');
    expect(chapters, hasLength(maxChapterListPages));
    expect(source.requestedPages, hasLength(maxChapterListPages));
  });

  test('an empty page ends the walk', () async {
    final source = _PagedSource(pages: [
      ['a'],
      <String>[],
      ['never'],
    ]);
    expect((await fetchAllChapters(source, 'm')).map((c) => c.id), ['a']);
    expect(source.requestedPages, [null, 2]);
  });
}

class _PagedSource implements MangaSource {
  _PagedSource({required this.pages})
      : repeatForever = false,
        endless = false;
  _PagedSource.repeating(List<String> page)
      : pages = [page],
        repeatForever = true,
        endless = false;
  _PagedSource.endless()
      : pages = const [],
        repeatForever = false,
        endless = true;

  final List<List<String>> pages;

  /// 忽略 page 参数、每次都回第一页的源。
  final bool repeatForever;

  /// 每页都给新话且永远说还有下一页的源。
  final bool endless;

  final List<int?> requestedPages = [];

  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) async {
    requestedPages.add(page);
    final n = page ?? 1;
    if (endless) {
      return Paged([Chapter(id: 'c$n', name: '第 $n 话')], hasNext: true);
    }
    if (repeatForever) {
      return Paged(
        [for (final id in pages.first) Chapter(id: id, name: id)],
        hasNext: true,
      );
    }
    if (n > pages.length) return const Paged([], hasNext: false);
    return Paged(
      [for (final id in pages[n - 1]) Chapter(id: id, name: id)],
      hasNext: n < pages.length,
    );
  }

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
