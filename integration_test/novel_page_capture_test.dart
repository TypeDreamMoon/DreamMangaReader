import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/features/novel/novel_document_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'captures a non-empty PNG and restores the visible page',
    (tester) async {
      final controller = WebNovelDocumentController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NovelDocumentView(controller: controller)),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      final body = List.generate(
        120,
        (index) => '<p>第 $index 段：这是用于验证分页截图和位置恢复的中文正文。</p>',
      ).join();
      await controller.loadChapter(
        'capture-test',
        NovelDocument(format: NovelDocumentFormat.html, content: body),
        const NovelReaderPreferences(),
      );

      final ready = await _waitForMultiplePages(controller);
      expect(ready.pageCount, greaterThan(1));
      await controller.showPage(1);
      final before = await controller.pageMetrics();

      final frame = await controller.capturePage(0);
      final after = await controller.pageMetrics();

      expect(frame, isNotNull);
      expect(frame!.bytes.length, greaterThan(8));
      expect(frame.bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(after.currentPageIndex, before.currentPageIndex);
    },
    skip: defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.windows,
  );
}

Future<NovelPageMetrics> _waitForMultiplePages(
  WebNovelDocumentController controller,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  var metrics = await controller.pageMetrics();
  while (metrics.pageCount <= 1 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    metrics = await controller.pageMetrics();
  }
  return metrics;
}
