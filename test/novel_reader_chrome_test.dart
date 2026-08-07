import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_chrome.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('chrome overlays preserve the reader viewport at target sizes',
      (tester) async {
    for (final size in const [
      Size(360, 800),
      Size(800, 1280),
      Size(1280, 720),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(_harness(chromeVisible: true));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byKey(const Key('reader-viewport'))), size);
      expect(find.byKey(const Key('novel-reader-top-bar')), findsOneWidget);
      expect(find.byKey(const Key('novel-reader-bottom-bar')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'viewport: $size');
    }
    addTearDown(() => tester.binding.setSurfaceSize(null));
  });

  testWidgets('narrow landscape moves secondary commands into overflow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness(chromeVisible: true));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('novel-reader-secondary-overflow')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('novel-reader-search')), findsNothing);
    expect(find.byKey(const Key('novel-reader-theme')), findsNothing);
    expect(find.byKey(const Key('novel-reader-settings')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status toggles affect only status items', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness(
      chromeVisible: false,
      showChapterName: true,
      showPageNumber: true,
      showBookProgress: true,
      showTime: true,
      showBattery: true,
    ));
    await tester.pumpAndSettle();

    final viewportBefore = tester.getRect(
      find.byKey(const Key('reader-viewport')),
    );
    for (final key in const [
      'novel-status-chapter',
      'novel-status-page',
      'novel-status-progress',
      'novel-status-time',
      'novel-status-battery',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }

    await tester.pumpWidget(_harness(
      chromeVisible: false,
      showChapterName: false,
      showPageNumber: false,
      showBookProgress: false,
      showTime: false,
      showBattery: false,
    ));
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byKey(const Key('reader-viewport'))),
        viewportBefore);
    for (final key in const [
      'novel-status-chapter',
      'novel-status-page',
      'novel-status-progress',
      'novel-status-time',
      'novel-status-battery',
    ]) {
      expect(find.byKey(Key(key)), findsNothing);
    }
  });
}

Widget _harness({
  required bool chromeVisible,
  bool showChapterName = true,
  bool showPageNumber = true,
  bool showBookProgress = true,
  bool showTime = true,
  bool showBattery = true,
}) {
  return MaterialApp(
    theme: buildTheme(AppThemeVariant.light),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(
            key: Key('reader-viewport'),
            color: Color(0xffeee5d1),
          ),
          NovelReaderStatusOverlay(
            visible: !chromeVisible,
            chapterTitle: '第一章 很长但必须保持单行并正确截断',
            currentPage: 3,
            pageCount: 12,
            bookProgress: .42,
            now: DateTime(2026, 8, 7, 13, 30),
            batteryLevel: 82,
            showChapterName: showChapterName,
            showPageNumber: showPageNumber,
            showBookProgress: showBookProgress,
            showTime: showTime,
            showBattery: showBattery,
            foregroundColor: const Color(0xff202124),
          ),
          NovelReaderChrome(
            visible: chromeVisible,
            bookTitle: '测试小说书名很长但不能溢出',
            chapterTitle: '第一章 很长但必须保持单行并正确截断',
            progress: .42,
            previewLabel: '42%  第 1/2 章',
            canPreviousChapter: true,
            canNextChapter: true,
            onBack: () {},
            onBookmark: () {},
            onMore: () {},
            onPreviousChapter: () {},
            onNextChapter: () {},
            onDirectory: () {},
            onSearch: () {},
            onTheme: () {},
            onSettings: () {},
            onProgressChanged: (_) {},
            onProgressChangeEnd: (_) {},
            onInteraction: () {},
            backgroundColor: const Color(0xe6ffffff),
            foregroundColor: const Color(0xff202124),
          ),
        ],
      ),
    ),
  );
}
