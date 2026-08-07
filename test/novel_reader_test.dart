import 'dart:async';

import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/features/novel/novel_document_view.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_page.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_settings_sheet.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeController implements NovelDocumentController {
  _FakeController({
    this.locator = const NovelLocator(chapterId: 'c1'),
  });

  NovelLocator locator;
  NovelLocator? lastRestored;
  String? loadedChapterId;
  NovelReaderPreferences? appliedPreferences;
  final List<String> loadedChapterIds = [];
  Completer<void>? captureGate;
  int applyPreferenceCalls = 0;

  @override
  ValueChanged<NovelReaderCommand>? onCommand;

  @override
  ValueChanged<NovelLocator>? onLocatorChanged;

  @override
  ValueChanged<NovelSelection?>? onSelectionChanged;

  @override
  ValueChanged<bool>? onCaptureStateChanged;

  @override
  Future<void> applyPreferences(NovelReaderPreferences preferences) async {
    applyPreferenceCalls++;
    appliedPreferences = preferences;
  }

  @override
  Future<NovelLocator> captureLocator() async {
    await captureGate?.future;
    return locator;
  }

  @override
  Future<NovelPageFrame?> capturePage(int pageIndex) async => null;

  @override
  Future<NovelPageMetrics> pageMetrics() async => const NovelPageMetrics(
        pageCount: 1,
        currentPageIndex: 0,
        viewport: NovelViewport(width: 1000, height: 1600),
        layoutFingerprint: 'test',
      );

  @override
  Future<void> showPage(int pageIndex) async {}

  @override
  Future<void> loadChapter(
    String chapterId,
    NovelDocument document,
    NovelReaderPreferences preferences,
  ) async {
    loadedChapterId = chapterId;
    loadedChapterIds.add(chapterId);
    if (locator.chapterId != chapterId) {
      locator = NovelLocator(chapterId: chapterId);
    }
  }

  @override
  Future<bool> nextPage() async => true;

  @override
  Future<bool> previousPage() async => true;

  @override
  Future<void> restoreLocator(NovelLocator value) async {
    lastRestored = value;
    locator = value;
  }
}

Future<({Widget widget, NovelLibraryStore store})> _readerHarness(
  _FakeController controller, {
  NovelReaderPreferences preferences = const NovelReaderPreferences(),
}) async {
  final store = NovelLibraryStore();
  await store.load();
  store.setPreferences(preferences);
  await store.flushPending();
  final widget = MaterialApp(
    // 小说界面走 palette(AppTokens 主题扩展),裸 MaterialApp 取不到。
    theme: buildTheme(AppThemeVariant.light),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: NovelLibraryScope(
      store: store,
      child: NovelReaderPage(
        novel: const Novel(id: 'n1', title: '测试小说'),
        chapters: const [
          NovelChapter(id: 'c1', title: '第一章'),
          NovelChapter(id: 'c2', title: '第二章'),
        ],
        initialIndex: 0,
        libraryKey: 'remote:s:n1',
        controller: controller,
        documentViewBuilder: (_, __) => const ColoredBox(color: Colors.black),
        loadDocument: (chapter) async => NovelDocument(
          format: NovelDocumentFormat.html,
          content: '<p>${chapter.title}</p>',
        ),
      ),
    ),
  );
  return (widget: widget, store: store);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('mode and typography changes preserve locator', (tester) async {
    final controller = _FakeController(
      locator: const NovelLocator(
        chapterId: 'c1',
        blockId: 'dmr-7',
        fraction: .3,
      ),
    );
    final harness = await _readerHarness(controller);
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-reader-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连续滚动'));
    await tester.pumpAndSettle();

    expect(controller.appliedPreferences?.mode, NovelReaderMode.scroll);
    expect(controller.lastRestored?.blockId, 'dmr-7');
    expect(controller.lastRestored?.fraction, .3);
  });

  testWidgets('directory selection loads the selected chapter', (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(controller);
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();
    expect(controller.loadedChapterId, 'c1');

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-reader-directory')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二章'));
    await tester.pumpAndSettle();

    expect(controller.loadedChapterId, 'c2');
  });

  testWidgets('wide reader directory opens as a side panel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _FakeController();
    final harness = await _readerHarness(controller);
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();
    await tester.tap(find.byKey(const Key('novel-reader-directory')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('novel-reader-directory-panel-wide')),
      findsOneWidget,
    );
    expect(find.text('第二章'), findsOneWidget);
  });

  testWidgets('latest rapid reader setting persists when reader closes',
      (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(controller);
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();
    await tester.tap(find.byKey(const Key('novel-reader-settings')));
    await tester.pumpAndSettle();
    final settings = tester.widget<NovelReaderSettingsSheet>(
      find.byType(NovelReaderSettingsSheet),
    );
    settings.onChanged(
      const NovelReaderPreferences(fontSize: 24, lineHeight: 1.9),
    );
    settings.onChanged(
      const NovelReaderPreferences(fontSize: 26, lineHeight: 2.1),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 33));
    await harness.store.flushPending();
    final restored = NovelLibraryStore();
    addTearDown(restored.dispose);
    await restored.load();

    expect(restored.preferences.fontSize, 26);
    expect(restored.preferences.lineHeight, 2.1);
  });

  testWidgets('closing reader cancels pending controller preference work',
      (tester) async {
    final controller = _FakeController()..captureGate = Completer<void>();
    final harness = await _readerHarness(controller);
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();
    await tester.tap(find.byKey(const Key('novel-reader-settings')));
    await tester.pumpAndSettle();
    final settings = tester.widget<NovelReaderSettingsSheet>(
      find.byType(NovelReaderSettingsSheet),
    );
    settings.onChanged(const NovelReaderPreferences(fontSize: 25));
    await tester.pump();
    expect(controller.applyPreferenceCalls, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.captureGate!.complete();
    await tester.pump();

    expect(controller.applyPreferenceCalls, 0);
  });

  testWidgets('reader starts immersive and center command reveals chrome',
      (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(controller);
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsNothing);
    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();
    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsOneWidget);
  });

  testWidgets('reader auto-hides chrome after configured delay',
      (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 1),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 999));
    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsNothing);
  });

  testWidgets('zero auto-hide keeps revealed chrome visible', (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 0),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsOneWidget);
  });

  testWidgets('whole-book slider seeks once on release and restores fraction',
      (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 0),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();
    final slider = tester.widget<Slider>(
      find.byKey(const Key('novel-reader-progress-slider')),
    );
    final loadsBefore = controller.loadedChapterIds.length;
    slider.onChanged!(.75);
    await tester.pump();
    expect(controller.loadedChapterIds.length, loadsBefore);

    slider.onChangeEnd!(.75);
    await tester.pumpAndSettle();
    expect(controller.loadedChapterIds.length, loadsBefore + 1);
    expect(controller.loadedChapterId, 'c2');
    expect(controller.lastRestored?.chapterId, 'c2');
    expect(controller.lastRestored?.fraction, .5);
  });

  test('reader HTML shell sanitizes HTML and escapes plain text', () {
    final html = buildNovelReaderHtml(NovelDocument(
      format: NovelDocumentFormat.html,
      content: '<p onclick="bad()">正文</p><script>bad()</script>',
    ));
    final text = buildNovelReaderHtml(NovelDocument(
      format: NovelDocumentFormat.text,
      content: '<script>只是文字</script>',
    ));

    expect(html, contains('Content-Security-Policy'));
    expect(html, contains("connect-src 'none'"));
    expect(html, isNot(contains('onclick')));
    expect(html, isNot(contains('<script>bad()')));
    expect(text, contains('&lt;script&gt;只是文字&lt;/script&gt;'));
    expect(
      novelReaderBridgeScript,
      contains('calc((100vw - 760px) / 2)'),
    );
    expect(novelReaderBridgeScript, contains('--dmr-side:max('));
    expect(
      novelReaderBridgeScript,
      contains(
        'column-width:calc(100vw - var(--dmr-side) - var(--dmr-side))',
      ),
    );
    expect(
      novelReaderBridgeScript,
      contains('column-gap:calc(var(--dmr-side) + var(--dmr-side))'),
    );
    expect(
        novelReaderBridgeScript, contains('img{max-width:100%;height:auto}'));
    expect(
      novelReaderBridgeScript,
      contains("closest?.('a,button,input,textarea,select,[contenteditable]')"),
    );
    expect(novelReaderBridgeScript, contains("addEventListener('wheel'"));
    expect(novelReaderBridgeScript, contains('{passive:false}'));
  });
}
