import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_paginator.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_render_document.dart';
import 'package:dream_manga_reader/features/novel/novel_native_document_controller.dart';
import 'package:dream_manga_reader/features/novel/novel_native_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NovelPaginationResult layout(Size size) => NovelPaginator.paginate(
        document: NovelRenderDocumentParser.parse(
          NovelDocument(
            format: NovelDocumentFormat.text,
            content: List.generate(
              12,
              (index) => '第${index + 1}段 ${List.filled(36, '正文内容').join()}',
            ).join('\n'),
          ),
        ),
        viewport: size,
        style: const NovelPageStyle(
          fontSize: 18,
          lineHeight: 1.6,
          paragraphSpacing: 10,
          firstLineIndent: 2,
          pagePadding: EdgeInsets.fromLTRB(26, 30, 26, 34),
        ),
      );

  Future<void> pumpReader(
    WidgetTester tester,
    Size size,
    NovelPaginationResult pagination,
  ) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: NovelNativePageView(
                pagination: pagination,
                spreadIndex: 0,
                canvasColor: const Color(0xffd7d2c4),
                pageColor: const Color(0xfff7f1df),
                textColor: const Color(0xff25231f),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders a single right leaf on phone layouts', (tester) async {
    const size = Size(420, 760);
    final pagination = layout(size);
    await pumpReader(tester, size, pagination);

    expect(find.byKey(const Key('novel-native-page-view')), findsOneWidget);
    expect(find.byKey(const Key('novel-leaf-left')), findsNothing);
    expect(find.byKey(const Key('novel-leaf-right')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('novel-leaf-right'))),
      pagination.leafRects.single,
    );
  });

  testWidgets('renders two separately addressable leaves on wide layouts',
      (tester) async {
    const size = Size(1180, 760);
    final pagination = layout(size);
    await pumpReader(tester, size, pagination);

    expect(find.byKey(const Key('novel-leaf-left')), findsOneWidget);
    expect(find.byKey(const Key('novel-leaf-right')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('novel-leaf-left'))),
      pagination.leafRects[0],
    );
    expect(
      tester.getRect(find.byKey(const Key('novel-leaf-right'))),
      pagination.leafRects[1],
    );
    expect(find.byKey(const Key('novel-book-spine')), findsOneWidget);
  });

  testWidgets('exposes painted page text and page number to semantics',
      (tester) async {
    const size = Size(420, 760);
    final pagination = layout(size);
    await pumpReader(tester, size, pagination);

    final semantics = tester.getSemantics(
      find.byKey(const Key('novel-leaf-right')),
    );
    expect(semantics.label, contains('第1段'));
    expect(semantics.value, '1');
  });

  test('page text cache releases its painters on dispose', () {
    final pagination = layout(const Size(420, 760));
    final page = pagination.pages.first;
    final cache = NovelPageTextCache();
    final painters = [
      for (final fragment in page.fragments)
        cache.painterFor(
          page: page,
          fragment: fragment,
          color: const Color(0xff25231f),
        ),
    ];

    expect(painters, isNotEmpty);
    // 同一页同一色再取一次必须命中缓存，否则就是「每帧重建」的老毛病。
    expect(
      cache.painterFor(
        page: page,
        fragment: page.fragments.first,
        color: const Color(0xff25231f),
      ),
      same(painters.first),
    );
    expect(cache.length, painters.length);

    cache.dispose();

    expect(cache.length, 0);
    for (final painter in painters) {
      expect(painter.debugDisposed, isTrue);
    }
  });

  test('page text cache drops the previous page instead of accumulating', () {
    final pagination = layout(const Size(420, 760));
    final cache = NovelPageTextCache();
    addTearDown(cache.dispose);
    final first = pagination.pages.first;
    final stale = cache.painterFor(
      page: first,
      fragment: first.fragments.first,
      color: const Color(0xff25231f),
    );

    final second = pagination.pages[1];
    cache.painterFor(
      page: second,
      fragment: second.fragments.first,
      color: const Color(0xff25231f),
    );

    expect(stale.debugDisposed, isTrue);
    expect(cache.length, 1);
  });

  testWidgets('releases page painters when the leaf leaves the tree',
      (tester) async {
    const size = Size(420, 760);
    await pumpReader(tester, size, layout(size));
    expect(find.byType(NovelNativePageCanvas), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(find.byType(NovelNativePageCanvas), findsNothing);
  });

  testWidgets('uses the selected canvas and page colors without a black layer',
      (tester) async {
    const size = Size(420, 760);
    await pumpReader(tester, size, layout(size));

    final canvas = tester.widget<ColoredBox>(
      find.byKey(const Key('novel-page-canvas-color')),
    );
    expect(canvas.color, const Color(0xffd7d2c4));
    final leaf = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byKey(const Key('novel-leaf-right')),
        matching: find.byKey(const Key('novel-page-paper-color')),
      ),
    );
    expect(leaf.color, const Color(0xfff7f1df));
  });

  test('scroll bands tile a slice without changing its total height', () {
    final pagination = layout(const Size(420, 760));
    final slices = [
      NovelScrollSlice(page: pagination.pages.first, top: 0, height: 5000),
      NovelScrollSlice(page: pagination.pages.last, top: 5000, height: 300),
    ];

    final bands = novelScrollBands(slices, bandExtent: 760);

    expect(bands, hasLength(8));
    expect(
      bands.fold<double>(0, (total, band) => total + band.height),
      closeTo(5300, .001),
    );
    // 一个切片内的带必须等高：ListView 就是按等高推算 maxScrollExtent 的。
    for (final band in bands.take(7)) {
      expect(band.height, closeTo(5000 / 7, .001));
    }
    expect(bands.last.height, closeTo(300, .001));
    // 带在页内逐段接龙，换页时重新从 0 开始。
    expect(bands.first.top, 0);
    expect(bands[1].top, closeTo(5000 / 7, .001));
    expect(bands.last.top, 0);
  });

  testWidgets('scroll mode builds only the bands it can show', (tester) async {
    const size = Size(420, 760);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          120,
          (index) => '第${index + 1}段 ${List.filled(30, '懒渲染正文').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(turnMode: NovelPageTurnMode.scroll),
    );
    // main 把 paginationFor 改成了「build 期间只读缓存、算完再通知」，
    // 测试要立刻拿到版面，走同步的 ensurePagination。
    final pagination = controller.ensurePagination(size)!;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: NovelNativeScrollView(
                controller: controller,
                pagination: pagination,
                canvasColor: const Color(0xffd7d2c4),
                pageColor: const Color(0xfff7f1df),
                textColor: const Color(0xff25231f),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final bands = novelScrollBands(
      controller.scrollSlices,
      bandExtent: size.height,
    );
    expect(bands.length, greaterThan(6));

    int paintedBands() => tester
        .widgetList<CustomPaint>(find.descendant(
          of: find.byKey(const Key('novel-native-scroll-view')),
          matching: find.byType(CustomPaint),
        ))
        .where((widget) => widget.painter is NovelNativePagePainter)
        .length;

    // 老实现把整章一次性摆进 Column，一个几万像素高的画布每帧重画全文。
    expect(paintedBands(), lessThan(bands.length));

    // 滞后量不变：滚到底也只多几带，而且可滚距离与排版总高逐像素对得上
    // —— locator 用的就是这个绝对偏移。
    final position = tester
        .state<ScrollableState>(find.descendant(
          of: find.byKey(const Key('novel-native-scroll-view')),
          matching: find.byType(Scrollable),
        ))
        .position;
    expect(
      position.maxScrollExtent,
      closeTo(controller.scrollContentHeight - size.height, 1),
    );

    controller.scrollController.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(paintedBands(), lessThan(bands.length));
    expect(tester.takeException(), isNull);
  });
}
