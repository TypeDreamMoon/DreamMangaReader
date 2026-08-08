import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
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
}
