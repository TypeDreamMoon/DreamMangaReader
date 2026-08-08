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
