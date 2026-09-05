import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_paginator.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_render_document.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final document = NovelRenderDocumentParser.parse(
    NovelDocument(
      format: NovelDocumentFormat.text,
      content: List.generate(
        18,
        (index) => '第${index + 1}段 ${List.filled(28, '用于验证分页的文字').join()}',
      ).join('\n'),
    ),
  );

  const style = NovelPageStyle(
    fontSize: 18,
    lineHeight: 1.65,
    paragraphSpacing: 12,
    firstLineIndent: 2,
    pagePadding: EdgeInsets.fromLTRB(28, 32, 28, 32),
    wideViewportThreshold: 900,
    spreadGutter: 28,
    maxLeafWidth: 620,
  );

  test('paginates every source character exactly once', () {
    final result = NovelPaginator.paginate(
      document: document,
      viewport: const Size(420, 760),
      style: style,
    );

    for (final block in document.blocks) {
      final fragments = result.pages
          .expand((page) => page.fragments)
          .where((fragment) => fragment.blockId == block.id)
          .toList();
      expect(fragments.map((fragment) => fragment.sourceText).join(),
          block.plainText);
      for (var index = 1; index < fragments.length; index++) {
        expect(fragments[index].sourceStart, fragments[index - 1].sourceEnd);
      }
    }
  });

  test('uses one centered leaf on narrow viewports', () {
    final result = NovelPaginator.paginate(
      document: document,
      viewport: const Size(420, 760),
      style: style,
    );

    expect(result.pagesPerSpread, 1);
    expect(result.spreads.first.leftPage, isNull);
    expect(result.spreads.first.rightPage, isNotNull);
    expect(result.leafRects, hasLength(1));
    expect(result.leafRects.single.width, lessThanOrEqualTo(420));
    expect(result.leafRects.single.center.dx, closeTo(210, .01));
    expect(result.pages.first.fragments.first.offset.dy, style.pagePadding.top);
  });

  test('uses two bounded leaves and a book gutter on wide viewports', () {
    final result = NovelPaginator.paginate(
      document: document,
      viewport: const Size(1440, 900),
      style: style,
    );

    expect(result.pagesPerSpread, 2);
    expect(result.leafRects, hasLength(2));
    expect(result.leafRects[0].width, lessThanOrEqualTo(620));
    expect(result.leafRects[1].width, lessThanOrEqualTo(620));
    expect(result.leafRects[1].left - result.leafRects[0].right, 28);
    expect(result.spreads.first.leftPage, isNotNull);
    expect(result.spreads.first.rightPage, isNotNull);
  });

  test('keeps a single centered leaf in a tall desktop window', () {
    final result = NovelPaginator.paginate(
      document: document,
      viewport: const Size(1000, 1400),
      style: style,
    );

    expect(result.pagesPerSpread, 1);
    expect(result.leafRects, hasLength(1));
    expect(result.leafRects.single.width, lessThanOrEqualTo(620));
    expect(result.leafRects.single.center.dx, closeTo(500, .01));
  });

  test('maps semantic locators back to the containing page and spread', () {
    final result = NovelPaginator.paginate(
      document: document,
      viewport: const Size(1180, 760),
      style: style,
    );
    final targetBlock = document.blocks[10];
    final offset = targetBlock.plainText.length ~/ 2;
    final pageIndex = result.pageIndexForLocator(
      NovelLocator(
        chapterId: 'chapter-1',
        blockId: targetBlock.id,
        charOffset: offset,
      ),
    );

    expect(pageIndex, isNotNull);
    final page = result.pages[pageIndex!];
    expect(
      page.fragments.any((fragment) =>
          fragment.blockId == targetBlock.id &&
          fragment.sourceStart <= offset &&
          fragment.sourceEnd >= offset),
      isTrue,
    );
    expect(result.spreadIndexForPage(pageIndex), pageIndex ~/ 2);
  });

  NovelRenderDocument longChapter(int characters) =>
      NovelRenderDocumentParser.parse(
        NovelDocument(
          format: NovelDocumentFormat.text,
          content: List.filled(characters, '章').join(),
        ),
      );

  test('paginates a 200k-character chapter in bounded time', () {
    const characters = 200000;
    NovelPaginator.debugResetCounters();
    final stopwatch = Stopwatch()..start();

    final result = NovelPaginator.paginate(
      document: longChapter(characters),
      viewport: const Size(420, 760),
      style: style,
    );
    stopwatch.stop();

    expect(result.pages.length, greaterThan(50));
    // 老实现每页都要给「剩余全文」的一半做一次 layout(O(N²)):同样这一章要跑
    // 四千多万字符、几十秒起步,改个字号就是一次 ANR。
    expect(
      NovelPaginator.debugLayoutCharacters,
      lessThan(characters * 40),
      reason: '分页测量的字符总数必须与正文长度成正比',
    );
    expect(stopwatch.elapsedMilliseconds, lessThan(8000));
  });

  test('scales pagination measurement linearly with chapter length', () {
    int measure(int characters) {
      NovelPaginator.debugResetCounters();
      NovelPaginator.paginate(
        document: longChapter(characters),
        viewport: const Size(420, 760),
        style: style,
      );
      return NovelPaginator.debugLayoutCharacters;
    }

    final half = measure(100000);
    final full = measure(200000);

    // 线性:翻倍正文最多翻倍多一点的测量量。二次复杂度会是四倍。
    expect(full, lessThan(half * 2.6));
  });

  test('disposes every TextPainter it creates while measuring', () {
    NovelPaginator.debugResetCounters();

    NovelPaginator.paginate(
      document: document,
      viewport: const Size(420, 760),
      style: style,
    );

    // TextPainter 背后是 engine 侧的 Paragraph：排版一章会造上千个探测用的
    // painter，漏掉任何一个都是原生内存泄漏。
    expect(NovelPaginator.debugCreatedTextPainters, greaterThan(0));
    expect(
      NovelPaginator.debugDisposedTextPainters,
      NovelPaginator.debugCreatedTextPainters,
    );
  });

  test('produces deterministic page boundaries for the same layout', () {
    NovelPaginationResult paginate() => NovelPaginator.paginate(
          document: document,
          viewport: const Size(420, 760),
          style: style,
        );

    final first = paginate();
    final second = paginate();
    expect(first.layoutFingerprint, second.layoutFingerprint);
    expect(
      first.pages.expand((page) => page.fragments).map((fragment) =>
          '${fragment.blockId}:${fragment.sourceStart}-${fragment.sourceEnd}'),
      second.pages.expand((page) => page.fragments).map((fragment) =>
          '${fragment.blockId}:${fragment.sourceStart}-${fragment.sourceEnd}'),
    );
  });
}
