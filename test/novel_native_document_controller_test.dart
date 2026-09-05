import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/features/novel/novel_native_document_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pre-rasterizes a captured spread into a reusable page image',
      (tester) async {
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          36,
          (index) => '第${index + 1}段 ${List.filled(28, '预加载正文').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(),
    );
    controller.ensurePagination(const Size(420, 720));

    final frame = await tester.runAsync(() => controller.capturePage(0));
    final metrics = await controller.pageMetrics();

    expect(frame, isNotNull);
    expect(frame!.bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(controller.pageImageFor(0), isNotNull);
    expect(controller.cachedPageImageCount, 1);
    expect(frame.key.layoutFingerprint, metrics.layoutFingerprint);
  });

  testWidgets('moves the three-spread raster window with the current page',
      (tester) async {
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          90,
          (index) => '第${index + 1}段 ${List.filled(32, '连续翻页正文').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(),
    );
    controller.ensurePagination(const Size(420, 720));

    await tester.runAsync(controller.preloadAroundCurrent);
    expect(controller.pageImageFor(0), isNotNull);
    expect(controller.pageImageFor(1), isNotNull);

    expect(await controller.nextPage(), isTrue);
    await tester.runAsync(controller.preloadAroundCurrent);

    expect(controller.pageImageFor(0), isNotNull);
    expect(controller.pageImageFor(1), isNotNull);
    expect(controller.pageImageFor(2), isNotNull);
    expect(controller.cachedPageImageCount, lessThanOrEqualTo(3));
  });

  testWidgets('a theme change retires cached page frames without repaginating',
      (tester) async {
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          30,
          (index) => '第${index + 1}段 ${List.filled(26, '换肤正文').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(),
    );
    controller.ensurePagination(const Size(420, 720));
    final layout = controller.pagination!.layoutFingerprint;
    final light = await tester.runAsync(() => controller.capturePage(0));

    await controller.applyPreferences(
      const NovelReaderPreferences(theme: NovelReaderTheme.black),
    );
    controller.ensurePagination(const Size(420, 720));
    final dark = await tester.runAsync(() => controller.capturePage(0));

    // 断行没变 —— 换主题不该重排整章。
    expect(controller.pagination!.layoutFingerprint, layout);
    // 但页帧 key 必须变,否则 NovelPageCache 会留着白天配色的位图。
    expect(
      dark!.key.layoutFingerprint,
      isNot(light!.key.layoutFingerprint),
    );
    expect(dark.bytes, isNot(light.bytes));
  });

  testWidgets('brightness and texture settings retire cached page frames',
      (tester) async {
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          20,
          (index) => '第${index + 1}段 ${List.filled(24, '亮度正文').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(),
    );
    controller.ensurePagination(const Size(420, 720));
    final base = await tester.runAsync(() => controller.capturePage(0));

    await controller.applyPreferences(
      const NovelReaderPreferences(brightness: .7),
    );
    controller.ensurePagination(const Size(420, 720));
    final dimmed = await tester.runAsync(() => controller.capturePage(0));

    expect(
      dimmed!.key.layoutFingerprint,
      isNot(base!.key.layoutFingerprint),
    );
  });

  testWidgets('defers pagination out of the build phase', (tester) async {
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          40,
          (index) => '第${index + 1}段 ${List.filled(30, '异步分页正文').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(),
    );

    // build 只读缓存:没有现成结果就先返回 null,别在 LayoutBuilder 里同步排版。
    expect(controller.paginationFor(const Size(420, 720)), isNull);
    expect(controller.pagination, isNull);

    var notified = 0;
    controller.addListener(() => notified++);
    await tester.pump();

    expect(controller.pagination, isNotNull);
    expect(notified, greaterThan(0));
    // 结果落进缓存,下一帧直接命中,不会每帧重排。
    expect(
      controller.paginationFor(const Size(420, 720)),
      same(controller.pagination),
    );
  });

  testWidgets('paints the chapter once the deferred pagination lands',
      (tester) async {
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          24,
          (index) => '第${index + 1}段 ${List.filled(24, '排版落地').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NovelNativeDocumentView(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('novel-native-page-view')), findsOneWidget);
  });

  testWidgets('scroll mode lays the whole chapter out as one scrollable column',
      (tester) async {
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          60,
          (index) => '第${index + 1}段 ${List.filled(30, '滚动模式正文').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(turnMode: NovelPageTurnMode.scroll),
    );

    final pagination = controller.ensurePagination(const Size(420, 720));

    expect(controller.isScrollMode, isTrue);
    // 整章排成一列,而不是切成一屏一页。
    expect(pagination!.pages, hasLength(1));
    expect(controller.scrollSlices, hasLength(1));
    // 内容比一屏高得多 —— 也就是真的有得滚。
    expect(controller.scrollContentHeight, greaterThan(720 * 3));
  });

  testWidgets('scroll position drives the reported reading locator',
      (tester) async {
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    final reported = <NovelLocator>[];
    controller.onLocatorChanged = reported.add;
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          60,
          (index) => '第${index + 1}段 ${List.filled(30, '进度同步正文').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(turnMode: NovelPageTurnMode.scroll),
    );
    controller.ensurePagination(const Size(420, 720));

    final maxExtent = controller.scrollContentHeight - 720;
    controller.reportScroll(maxExtent / 2, maxExtent);

    expect(reported, isNotEmpty);
    expect(reported.last.chapterId, 'chapter-1');
    expect(reported.last.fraction, closeTo(.5, .01));
    expect(reported.last.blockId, isNotNull);

    // 同一位置微动不再重复上报:滚动一帧一次 setState + 写盘正是卡顿来源。
    final before = reported.length;
    controller.reportScroll(maxExtent / 2 + 1, maxExtent);
    expect(reported, hasLength(before));

    // 定位能还原回同一段正文(锚点段落被摆回屏幕顶端)。
    final anchor = reported.last;
    controller.reportScroll(0, maxExtent);
    await controller.restoreLocator(anchor);
    final restored = controller.takePendingScrollOffset();
    expect(restored, isNotNull);
    controller.reportScroll(restored!, maxExtent);
    expect((await controller.captureLocator()).blockId, anchor.blockId);
  });
}
