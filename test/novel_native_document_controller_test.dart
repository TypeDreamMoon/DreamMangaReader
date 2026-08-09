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
    controller.paginationFor(const Size(420, 720));

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
    controller.paginationFor(const Size(420, 720));

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

    final pagination = controller.paginationFor(const Size(420, 720));

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
    controller.paginationFor(const Size(420, 720));

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
