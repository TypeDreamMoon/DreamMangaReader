import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/platform/reader_keys.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_background_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_font_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_page_turn_physics.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_data.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_data_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_theme.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_search_index.dart';
import 'package:dream_manga_reader/features/novel/novel_document_view.dart';
import 'package:dream_manga_reader/features/novel/novel_native_document_controller.dart';
import 'package:dream_manga_reader/features/novel/novel_native_page_view.dart';
import 'package:dream_manga_reader/features/novel/novel_native_page_turn_surface.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_input.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_page.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_settings_sheet.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeController implements NovelDocumentController,
    NovelPaginationSignals {
  _FakeController({
    this.locator = const NovelLocator(chapterId: 'c1'),
    this.supportsPageFrames = false,
    this.pageCount = 3,
    this.turnsWithinDocument = true,
  });

  NovelLocator locator;
  final bool supportsPageFrames;
  int pageCount;
  final bool turnsWithinDocument;
  int visiblePageIndex = 0;
  final List<int> shownPages = [];
  NovelLocator? lastRestored;
  String? loadedChapterId;
  NovelReaderPreferences? appliedPreferences;
  final List<String> loadedChapterIds = [];
  Completer<void>? captureGate;
  int applyPreferenceCalls = 0;
  int visibleTextLength = 100;
  bool fontLoadFailed = false;
  String? failApplyingFontId;
  final List<NovelReaderPreferences> preferenceHistory = [];
  final List<NovelAnnotation> appliedAnnotations = [];
  final List<NovelLocator> searchHighlights = [];
  int clearSelectionCalls = 0;

  /// 非 null 且未完成 = 「排版还在跑」。
  Completer<void>? paginationGate;

  @override
  bool get hasPagination => paginationGate?.isCompleted ?? true;

  @override
  Future<void> get paginationReady =>
      paginationGate?.future ?? Future<void>.value();

  @override
  ValueChanged<NovelReaderCommand>? onCommand;

  @override
  ValueChanged<NovelLocator>? onLocatorChanged;

  @override
  ValueChanged<NovelSelection?>? onSelectionChanged;

  @override
  ValueChanged<bool>? onCaptureStateChanged;

  @override
  ValueChanged<Set<String>>? onUnresolvedAnnotationsChanged;

  @override
  Future<Set<String>> applyAnnotations(
    Iterable<NovelAnnotation> annotations,
  ) async {
    appliedAnnotations
      ..clear()
      ..addAll(annotations);
    onUnresolvedAnnotationsChanged?.call(const {});
    return const {};
  }

  @override
  Future<void> clearSelection() async {
    clearSelectionCalls++;
    onSelectionChanged?.call(null);
  }

  @override
  Future<void> showSearchResult(NovelLocator locator) async {
    searchHighlights.add(locator);
  }

  @override
  Future<void> applyPreferences(NovelReaderPreferences preferences) async {
    applyPreferenceCalls++;
    appliedPreferences = preferences;
    preferenceHistory.add(preferences);
    if (preferences.fontFamily == failApplyingFontId) {
      throw StateError('font apply failed');
    }
  }

  @override
  Future<NovelLocator> captureLocator() async {
    await captureGate?.future;
    return locator;
  }

  @override
  Future<NovelPageFrame?> capturePage(int pageIndex) async {
    if (!supportsPageFrames) return null;
    onCaptureStateChanged?.call(true);
    try {
      return _testPageFrame(
        chapterId: loadedChapterId ?? locator.chapterId,
        pageIndex: pageIndex,
      );
    } finally {
      onCaptureStateChanged?.call(false);
    }
  }

  @override
  Future<NovelPageMetrics> pageMetrics() async => NovelPageMetrics(
        pageCount: supportsPageFrames ? pageCount : 1,
        currentPageIndex: visiblePageIndex,
        viewport: const NovelViewport(width: 1000, height: 1600),
        layoutFingerprint: hasPagination ? 'test-layout' : '',
        visibleTextLength: visibleTextLength,
        fontLoadFailed: fontLoadFailed,
      );

  @override
  Future<void> showPage(int pageIndex) async {
    visiblePageIndex = pageIndex;
    shownPages.add(pageIndex);
    locator = NovelLocator(
      chapterId: loadedChapterId ?? locator.chapterId,
      fraction: pageCount <= 1 ? 0 : pageIndex / (pageCount - 1),
    );
  }

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
  Future<bool> nextPage() async => turnsWithinDocument;

  @override
  Future<bool> previousPage() async => turnsWithinDocument;

  @override
  Future<void> restoreLocator(NovelLocator value) async {
    lastRestored = value;
    locator = value;
  }
}

/// 原生分页器在 widget 测试里没法真正光栅化(toByteData 依赖真实事件循环),
/// 这个替身只保留「原生控制器」这个身份和分页数据,让阅读页走原生那条分支。
class _StubNativeController extends NovelNativeDocumentController {
  int spread = 0;
  final List<int> shownPages = [];

  static const int _pages = 3;

  // 这个桩直接给出 pageMetrics、不走真正的排版,所以要自己宣布「版面已就绪」——
  // 否则阅读页会一直等 paginationReady,而它永远不会兑现。
  @override
  bool get hasPagination => true;

  @override
  Future<void> get paginationReady => Future<void>.value();

  @override
  Future<void> loadChapter(
    String chapterId,
    NovelDocument document,
    NovelReaderPreferences preferences,
  ) async {}

  @override
  Future<NovelPageMetrics> pageMetrics() async => NovelPageMetrics(
        pageCount: _pages,
        currentPageIndex: spread,
        viewport: const NovelViewport(width: 800, height: 600),
        layoutFingerprint: 'test-layout',
        visibleTextLength: 100,
      );

  @override
  Future<NovelPageFrame?> capturePage(int pageIndex) async {
    if (pageIndex < 0 || pageIndex >= _pages) return null;
    return _testPageFrame(chapterId: 'c1', pageIndex: pageIndex);
  }

  @override
  bool canTurn(NovelTurnDirection direction) =>
      direction == NovelTurnDirection.next ? spread < _pages - 1 : spread > 0;

  @override
  Future<void> showPage(int pageIndex) async {
    spread = pageIndex;
    shownPages.add(pageIndex);
  }

  @override
  Future<NovelLocator> captureLocator() async =>
      NovelLocator(chapterId: 'c1', fraction: spread / (_pages - 1));

  @override
  Future<void> restoreLocator(NovelLocator locator) async {}

  @override
  Future<void> applyPreferences(NovelReaderPreferences preferences) async {}
}

class _MemoryNovelReaderDataStore extends NovelReaderDataStore {
  final Map<String, NovelReaderBookData> values = {};

  @override
  Future<NovelReaderBookData> loadBook(String bookKey) async =>
      values.putIfAbsent(bookKey, () => NovelReaderBookData.empty(bookKey));

  @override
  void saveBook(NovelReaderBookData data) => values[data.bookKey] = data;

  @override
  Future<void> flushPending() async {}
}

Future<({Widget widget, NovelLibraryStore store})> _readerHarness(
  NovelDocumentController? controller, {
  NovelReaderPreferences preferences = const NovelReaderPreferences(),
  NovelDocumentLoader? loadDocument,
  NovelReaderDataStore? readerDataStore,
  NovelSearchIndex? searchIndex,
  NovelSearchDocumentLoader? loadCachedDocument,
  bool useDefaultDocumentView = false,
  List<NovelChapter> chapters = const [
    NovelChapter(id: 'c1', title: '第一章'),
    NovelChapter(id: 'c2', title: '第二章'),
  ],
  int initialIndex = 0,
  bool resumeFromHistory = false,
  NovelLocator? savedProgress,
  LibraryStore? libraryStore,
}) async {
  final store = NovelLibraryStore();
  await store.load();
  store.setPreferences(preferences);
  if (savedProgress != null) {
    store.saveProgress('remote:s:n1', savedProgress);
  }
  await store.flushPending();
  final page = MaterialApp(
    // 小说界面走 palette(AppTokens 主题扩展),裸 MaterialApp 取不到。
    theme: buildTheme(AppThemeVariant.light),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: NovelLibraryScope(
      store: store,
      child: NovelReaderPage(
        novel: const Novel(id: 'n1', title: '测试小说'),
        chapters: chapters,
        initialIndex: initialIndex,
        libraryKey: 'remote:s:n1',
        resumeFromHistory: resumeFromHistory,
        controller: controller,
        documentViewBuilder: useDefaultDocumentView
            ? null
            : (_, __) => const ColoredBox(color: Colors.black),
        readerDataStore: readerDataStore,
        searchIndex: searchIndex,
        loadCachedDocument: loadCachedDocument,
        loadDocument: loadDocument ??
            (chapter) async => NovelDocument(
                  format: NovelDocumentFormat.html,
                  content: '<p>${chapter.title}</p>',
                ),
      ),
    ),
  );
  final widget = libraryStore == null
      ? page
      : LibraryScope(store: libraryStore, child: page);
  return (widget: widget, store: store);
}

NovelPageFrame _testPageFrame({
  required String chapterId,
  required int pageIndex,
}) {
  return NovelPageFrame(
    key: NovelPageKey(
      chapterId: chapterId,
      pageIndex: pageIndex,
      layoutFingerprint: 'test-layout',
    ),
    viewport: const NovelViewport(width: 1000, height: 1600),
    bytes: base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
      'AAAADUlEQVR42mNk+M/wHwAF/gL+X1n0WQAAAABJRU5ErkJggg==',
    ),
  );
}

class _MissingNovelBackgroundStore extends NovelBackgroundStore {
  @override
  Future<NovelBackgroundRecord?> resolve(String id) async => null;
}

class _ImmediateNovelFontStore extends NovelFontStore {
  @override
  Future<NovelFontRecord> resolveForUse(String id) async => NovelFontRecord(
        id: NovelFontIds.notoSerifSc,
        displayName: 'Noto Serif SC',
        cssFamily: 'DMR Noto Serif SC',
        file: File('font.otf'),
      );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('directory entry opens the tapped chapter, not saved progress',
      (tester) async {
    final controller = _FakeController(
      locator: const NovelLocator(chapterId: 'c1'),
    );
    final harness = await _readerHarness(
      controller,
      chapters: const [
        NovelChapter(id: 'c1', title: '第一章'),
        NovelChapter(id: 'c2', title: '第二章'),
        NovelChapter(id: 'c3', title: '第三章'),
      ],
      initialIndex: 0,
      savedProgress: const NovelLocator(chapterId: 'c3', fraction: .8),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    expect(controller.loadedChapterId, 'c1');
    expect(controller.lastRestored, isNull);
    expect(find.text('第一章'), findsWidgets);
  });

  testWidgets('resume entry still opens the chapter saved in history',
      (tester) async {
    final controller = _FakeController(
      locator: const NovelLocator(chapterId: 'c1'),
    );
    final harness = await _readerHarness(
      controller,
      chapters: const [
        NovelChapter(id: 'c1', title: '第一章'),
        NovelChapter(id: 'c2', title: '第二章'),
        NovelChapter(id: 'c3', title: '第三章'),
      ],
      initialIndex: 0,
      resumeFromHistory: true,
      savedProgress: const NovelLocator(chapterId: 'c3', fraction: .8),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    expect(controller.loadedChapterId, 'c3');
    expect(controller.lastRestored?.chapterId, 'c3');
    expect(controller.lastRestored?.fraction, .8);
  });

  testWidgets('tapping the chapter already in history keeps its fraction',
      (tester) async {
    final controller = _FakeController(
      locator: const NovelLocator(chapterId: 'c2'),
    );
    final harness = await _readerHarness(
      controller,
      chapters: const [
        NovelChapter(id: 'c1', title: '第一章'),
        NovelChapter(id: 'c2', title: '第二章'),
        NovelChapter(id: 'c3', title: '第三章'),
      ],
      initialIndex: 1,
      savedProgress: const NovelLocator(chapterId: 'c2', fraction: .4),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    expect(controller.loadedChapterId, 'c2');
    expect(controller.lastRestored?.fraction, .4);
  });

  testWidgets('selection highlight and toolbar bookmark persist reader data',
      (tester) async {
    final dataStore = _MemoryNovelReaderDataStore();
    final controller = _FakeController(
      locator: const NovelLocator(
        chapterId: 'c1',
        blockId: 'dmr-1',
        charOffset: 0,
        quote: '测试正文',
      ),
    );
    final harness = await _readerHarness(
      controller,
      readerDataStore: dataStore,
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    controller.onSelectionChanged!(
      const NovelSelection(
        text: '测试正文',
        start: NovelLocator(
          chapterId: 'c1',
          blockId: 'dmr-1',
          charOffset: 0,
          quote: '测试正文',
        ),
        end: NovelLocator(
          chapterId: 'c1',
          blockId: 'dmr-1',
          charOffset: 4,
          quote: '',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('novel-selection-highlight')));
    await tester.pump(const Duration(milliseconds: 100));

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();
    await tester.tap(find.byKey(const Key('novel-reader-bookmark')));
    await tester.pump(const Duration(milliseconds: 100));
    final data = await dataStore.loadBook('remote:s:n1');
    expect(
      data.annotations.values.where((value) => !value.isDeleted),
      hasLength(1),
    );
    expect(
      data.bookmarks.values.where((value) => !value.isDeleted),
      hasLength(1),
    );
    expect(controller.appliedAnnotations, hasLength(1));
    expect(controller.clearSelectionCalls, 1);
  });

  testWidgets('editing a stored annotation blocks reader input',
      (tester) async {
    final dataStore = _MemoryNovelReaderDataStore();
    final annotation = NovelAnnotation.create(
      bookKey: 'remote:s:n1',
      range: NovelAnnotationRange.fromSelection(
        const NovelSelection(
          text: '测试正文',
          start: NovelLocator(
            chapterId: 'c1',
            blockId: 'dmr-1',
            charOffset: 0,
          ),
          end: NovelLocator(
            chapterId: 'c1',
            blockId: 'dmr-1',
            charOffset: 4,
          ),
        ),
      ),
      colorId: 'yellow',
      note: '原笔记',
      createdAt: 1000,
    );
    dataStore.values['remote:s:n1'] = NovelReaderBookData(
      bookKey: 'remote:s:n1',
      annotations: {annotation.id: annotation},
    );
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      readerDataStore: dataStore,
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-reader-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-tools-tab-notes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑笔记'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('novel-note-editor')), findsOneWidget);
    expect(
      tester.widget<NovelReaderInput>(find.byType(NovelReaderInput)).blocked,
      isTrue,
    );
  });

  testWidgets('reader search opens results and restores their locator',
      (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      searchIndex: _ImmediateSearchIndex(),
      loadCachedDocument: (_) async => NovelDocument(
        format: NovelDocumentFormat.text,
        content: '目标正文',
      ),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-reader-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('novel-search-query')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('novel-search-query')),
      '目标',
    );
    await tester.tap(find.byKey(const Key('novel-search-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('前文目标后文'));
    await tester.pumpAndSettle();

    expect(controller.lastRestored?.chapterId, 'c2');
    expect(controller.lastRestored?.quote, '目标');
    expect(controller.searchHighlights.single.quote, '目标');
  });

  testWidgets('cached paging saves progress only after settlement',
      (tester) async {
    final controller = _FakeController(supportsPageFrames: true);
    final harness = await _readerHarness(controller);
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    expect(harness.store.progressFor('remote:s:n1'), isNull);
    final gesture = await tester.startGesture(const Offset(700, 300));
    await gesture.moveTo(const Offset(300, 305));
    await tester.pump();
    expect(
      find.byKey(const Key('novel-page-turn-surface')),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));

    expect(harness.store.progressFor('remote:s:n1'), isNull);
    await tester.pumpAndSettle();

    expect(controller.shownPages, contains(1));
    expect(harness.store.progressFor('remote:s:n1')?.fraction, .5);
  });

  testWidgets('chapter boundary primes the adjacent chapter document',
      (tester) async {
    final loaded = <String>[];
    final controller = _FakeController(
      supportsPageFrames: true,
      pageCount: 1,
    );
    final harness = await _readerHarness(
      controller,
      loadDocument: (chapter) async {
        loaded.add(chapter.id);
        return NovelDocument(
          format: NovelDocumentFormat.html,
          content: '<p>${chapter.title}</p>',
        );
      },
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    expect(loaded, containsAllInOrder(['c1', 'c2']));
  });

  testWidgets('a viewport change repaginates and keeps the reading position',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = _FakeController(supportsPageFrames: true, pageCount: 4);
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 0),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    String pageStatus() =>
        tester.widget<Text>(find.byKey(const Key('novel-status-page'))).data!;
    expect(pageStatus(), '1/4');

    // 旋转:版面变了,分页数跟着变。
    controller.pageCount = 7;
    controller.locator = const NovelLocator(chapterId: 'c1', fraction: .5);
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.pump();
    // 去抖窗口 + 重排。
    for (var attempt = 0; attempt < 24; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(pageStatus(), '1/7');
    expect(controller.lastRestored?.fraction, .5);
  });

  testWidgets('chapter text cache keeps only the chapters around the reader',
      (tester) async {
    final requests = <String>[];
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      chapters: const [
        NovelChapter(id: 'c1', title: '第一章'),
        NovelChapter(id: 'c2', title: '第二章'),
        NovelChapter(id: 'c3', title: '第三章'),
        NovelChapter(id: 'c4', title: '第四章'),
        NovelChapter(id: 'c5', title: '第五章'),
      ],
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 0),
      loadDocument: (chapter) async {
        requests.add(chapter.id);
        return NovelDocument(
          format: NovelDocumentFormat.html,
          content: '<p>${chapter.title}</p>',
        );
      },
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    Future<void> jump(String key) async {
      controller.onCommand!(NovelReaderCommand.toggleControls);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    for (var step = 0; step < 3; step++) {
      await jump('novel-reader-next-chapter');
    }
    expect(requests, ['c1', 'c2', 'c3', 'c4']);

    // ±2 之内的章还在缓存里,回头不用重拉。
    await jump('novel-reader-previous-chapter');
    await jump('novel-reader-previous-chapter');
    expect(requests, ['c1', 'c2', 'c3', 'c4']);

    // c1 早在读到 c4 时就被释放了 —— 老实现会一直攒着整本书。
    await jump('novel-reader-previous-chapter');
    expect(requests, ['c1', 'c2', 'c3', 'c4', 'c1']);
  });

  testWidgets('a prefetched chapter is reused instead of fetched again',
      (tester) async {
    final requests = <String>[];
    final controller = _FakeController(
      supportsPageFrames: true,
      pageCount: 1,
      turnsWithinDocument: false,
    );
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 0),
      loadDocument: (chapter) async {
        requests.add(chapter.id);
        return NovelDocument(
          format: NovelDocumentFormat.html,
          content: '<p>${chapter.title}</p>',
        );
      },
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();
    // 章尾:c2 已经被预取过一次。
    expect(requests, ['c1', 'c2']);

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-reader-next-chapter')));
    await tester.pumpAndSettle();

    // 老实现把预取结果丢了,翻过去还要再拉一次 c2。
    expect(requests, ['c1', 'c2']);
    expect(controller.loadedChapterId, 'c2');
  });

  testWidgets('concurrent requests for one chapter share a single fetch',
      (tester) async {
    final requests = <String>[];
    final gate = Completer<NovelDocument>();
    final controller = _FakeController(
      supportsPageFrames: true,
      pageCount: 1,
      turnsWithinDocument: false,
    );
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 0),
      loadDocument: (chapter) {
        requests.add(chapter.id);
        if (chapter.id == 'c2') return gate.future;
        return Future.value(
          NovelDocument(
            format: NovelDocumentFormat.html,
            content: '<p>${chapter.title}</p>',
          ),
        );
      },
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();
    expect(requests, ['c1', 'c2']);

    // 预取还在路上就翻过去:复用同一个请求,不再发第二次。
    await tester.tapAt(const Offset(760, 300));
    await tester.pump();
    expect(requests, ['c1', 'c2']);

    gate.complete(
      NovelDocument(format: NovelDocumentFormat.html, content: '<p>第二章</p>'),
    );
    await tester.pumpAndSettle();
    expect(requests, ['c1', 'c2']);
    expect(controller.loadedChapterId, 'c2');
  });

  testWidgets('chapter loading keeps the cached edge page visible',
      (tester) async {
    final nextChapter = Completer<NovelDocument>();
    final controller = _FakeController(
      supportsPageFrames: true,
      pageCount: 1,
      turnsWithinDocument: false,
    );
    final harness = await _readerHarness(
      controller,
      loadDocument: (chapter) {
        if (chapter.id == 'c2') return nextChapter.future;
        return Future.value(
          NovelDocument(
            format: NovelDocumentFormat.html,
            content: '<p>${chapter.title}</p>',
          ),
        );
      },
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(760, 300));
    await tester.pump();

    expect(
      find.byKey(const Key('novel-page-turn-surface')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('novel-reader-edge-loading')),
      findsOneWidget,
    );

    nextChapter.complete(
      NovelDocument(
        format: NovelDocumentFormat.html,
        content: '<p>第二章</p>',
      ),
    );
    await tester.pumpAndSettle();
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

  testWidgets(
      'reported font load failure rolls a font change back with an error',
      (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(controller);
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();
    controller.fontLoadFailed = true;

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();
    await tester.tap(find.byKey(const Key('novel-reader-settings')));
    await tester.pumpAndSettle();
    final settings = tester.widget<NovelReaderSettingsSheet>(
      find.byType(NovelReaderSettingsSheet),
    );
    settings.onChanged(
      const NovelReaderPreferences(fontFamily: NovelFontIds.lxgwWenKai),
    );
    await tester.pumpAndSettle();

    expect(harness.store.preferences.fontFamily, NovelFontIds.notoSerifSc);
    expect(
        controller.preferenceHistory.last.fontFamily, NovelFontIds.notoSerifSc);
    expect(find.textContaining('字体加载失败'), findsOneWidget);
  });

  testWidgets('font application exception restores the previous preference',
      (tester) async {
    final controller = _FakeController()
      ..failApplyingFontId = NovelFontIds.lxgwWenKai;
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
      const NovelReaderPreferences(fontFamily: NovelFontIds.lxgwWenKai),
    );
    await tester.pumpAndSettle();

    expect(harness.store.preferences.fontFamily, NovelFontIds.notoSerifSc);
    expect(
      controller.preferenceHistory.last.fontFamily,
      NovelFontIds.notoSerifSc,
    );
    expect(controller.lastRestored?.chapterId, 'c1');
    expect(find.textContaining('字体加载失败'), findsOneWidget);
  });

  testWidgets('missing background fallback clears the persisted local ID',
      (tester) async {
    final backgroundId =
        '${NovelBackgroundIds.importedPrefix}${List.filled(64, 'd').join()}';
    final controller = WebNovelDocumentController(
      fontStore: _ImmediateNovelFontStore(),
      backgroundStore: _MissingNovelBackgroundStore(),
    );
    final harness = await _readerHarness(
      controller,
      preferences: NovelReaderPreferences(backgroundAssetId: backgroundId),
    );
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
      harness.store.preferences.copyWith(fontSize: 19),
    );
    await tester.pumpAndSettle();
    await harness.store.flushPending();

    final restored = NovelLibraryStore();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.preferences.backgroundAssetId, isNull);
    for (var attempt = 0; attempt < 21; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
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

  testWidgets('chapter buttons jump directly between chapters', (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 0),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-reader-next-chapter')));
    await tester.pumpAndSettle();
    expect(controller.loadedChapterId, 'c2');

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-reader-previous-chapter')));
    await tester.pumpAndSettle();
    expect(controller.loadedChapterId, 'c1');
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

  testWidgets('reader mounts configured status items outside chrome',
      (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(
        showBattery: false,
        toolbarAutoHideSeconds: 0,
      ),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsNothing);
    expect(find.byKey(const Key('novel-status-chapter')), findsOneWidget);
    expect(find.byKey(const Key('novel-status-page')), findsOneWidget);
    expect(find.byKey(const Key('novel-status-progress')), findsOneWidget);
    expect(find.byKey(const Key('novel-status-time')), findsOneWidget);
    expect(find.byKey(const Key('novel-status-battery')), findsNothing);
  });

  testWidgets('reader theme drives solid chrome and system bar contrast',
      (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(
        theme: NovelReaderTheme.white,
        toolbarAutoHideSeconds: 0,
      ),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pump();

    final profile = novelReaderThemeProfile(NovelReaderTheme.white);
    final bottomBar = tester.widget<DecoratedBox>(
      find.byKey(const Key('novel-reader-bottom-bar')),
    );
    final decoration = bottomBar.decoration as BoxDecoration;
    expect(decoration.color, Color(profile.chromeArgb));
    expect(decoration.gradient, isNull);

    final overlays = tester.widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
    );
    expect(
      overlays.any(
        (region) =>
            region.value.statusBarColor == Color(profile.systemBarArgb) &&
            region.value.statusBarIconBrightness == Brightness.dark,
      ),
      isTrue,
    );
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
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsNothing);
  });

  testWidgets('open reader sheet pauses chrome auto-hide', (tester) async {
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 1),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    controller.onCommand!(NovelReaderCommand.toggleControls);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-reader-directory')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 999));
    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pumpAndSettle();
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

  testWidgets('default reader uses native pages and advances without WebView',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final harness = await _readerHarness(
      null,
      useDefaultDocumentView: true,
      loadDocument: (chapter) async => NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          40,
          (index) => '第${index + 1}段 ${List.filled(32, '原生阅读正文').join()}',
        ).join('\n'),
      ),
    );
    addTearDown(harness.store.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    expect(find.byType(NovelNativePageView), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    final before =
        tester.getSemantics(find.byKey(const Key('novel-leaf-right'))).value;
    await tester.tapAt(const Offset(390, 380));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(NovelNativePageTurnSurface), findsOneWidget);
    expect(find.byKey(const Key('novel-native-page-back')), findsOneWidget);
    await tester.pumpAndSettle();
    final after =
        tester.getSemantics(find.byKey(const Key('novel-leaf-right'))).value;
    expect(int.parse(after), greaterThan(int.parse(before)));
  });

  testWidgets('cover mode advances a native page instead of freezing',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final harness = await _readerHarness(
      null,
      useDefaultDocumentView: true,
      preferences: const NovelReaderPreferences(
        turnMode: NovelPageTurnMode.cover,
      ),
      loadDocument: (chapter) async => NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          40,
          (index) => '第${index + 1}段 ${List.filled(32, '覆盖翻页正文').join()}',
        ).join('\n'),
      ),
    );
    addTearDown(harness.store.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    int page() => int.parse(
          tester.getSemantics(find.byKey(const Key('novel-leaf-right'))).value,
        );

    final before = page();
    await tester.tapAt(const Offset(390, 380));
    await tester.pumpAndSettle();
    final afterFirst = page();
    // 之前覆盖/平移/无动画三种模式在原生分页器下没有任何翻页层负责收尾,状态机卡在
    // settling:第一次点击就再也回不到 idle,后续点击全部只是入队 —— 阅读器点不动,
    // 进度条也随之停更。这里连点两次,专门盯住「第二次还能不能翻」。
    expect(afterFirst, greaterThan(before));

    await tester.tapAt(const Offset(390, 380));
    await tester.pumpAndSettle();
    expect(page(), greaterThan(afterFirst));
    expect(
      harness.store.progressFor('remote:s:n1')?.fraction ?? 0,
      greaterThan(0),
    );
  });

  testWidgets('a stale chapter load never reloads the chapter behind us',
      (tester) async {
    final gates = <Completer<NovelDocument>>[];
    final controller = _FakeController();
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(toolbarAutoHideSeconds: 0),
      loadDocument: (chapter) {
        final gate = Completer<NovelDocument>();
        gates.add(gate);
        return gate.future;
      },
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pump();

    // 首章还没加载完,转圈动画一直在跑,pumpAndSettle 永远等不到静止。
    Future<void> settle() async {
      for (var attempt = 0; attempt < 16; attempt++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    final directory = find.byKey(const Key('novel-reader-directory'));
    Future<void> pickChapter(String title) async {
      // 关目录时 _resumeControls 会把工具栏留着,别再 toggle 一次给关掉。
      if (directory.evaluate().isEmpty) {
        controller.onCommand!(NovelReaderCommand.toggleControls);
        await settle();
      }
      await tester.tap(directory);
      await settle();
      await tester.tap(find.text(title));
      await settle();
    }

    // c1(第一次,还在路上)→ c2 → c1(第二次,复用同一个在途请求)。
    await pickChapter('第二章');
    await pickChapter('第一章');
    expect(gates, hasLength(2));

    // 这一下同时唤醒两次 c1 加载:老的那次必须被代际挡掉,只留最新的一次。
    gates[0].complete(
      NovelDocument(format: NovelDocumentFormat.text, content: '第一章正文'),
    );
    await settle();
    expect(controller.loadedChapterIds, ['c1']);
    expect(controller.lastRestored?.chapterId, 'c1');
  });

  testWidgets('novel reader takes volume keys only when the switch is on',
      (tester) async {
    const channel = MethodChannel('dream_manga_reader/reader_keys');
    final activations = <bool>[];
    ReaderKeys.debugReset();
    ReaderKeys.debugSupportedOverride = true;
    addTearDown(ReaderKeys.debugReset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setVolumeKeyPaging') {
        activations.add(call.arguments as bool);
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final library = LibraryStore();
    addTearDown(library.dispose);
    await library.load();

    final off = await _readerHarness(_FakeController(), libraryStore: library);
    addTearDown(off.store.dispose);
    await tester.pumpWidget(off.widget);
    await tester.pumpAndSettle();
    expect(activations, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    library.volumeKeyPaging = true;
    final on = await _readerHarness(_FakeController(), libraryStore: library);
    addTearDown(on.store.dispose);
    await tester.pumpWidget(on.widget);
    await tester.pumpAndSettle();
    expect(activations, [true]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(activations, [true, false]);
  });

  testWidgets('page level keyboard shortcuts reach the mounted reader',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final harness = await _readerHarness(
      null,
      useDefaultDocumentView: true,
      preferences: const NovelReaderPreferences(
        turnMode: NovelPageTurnMode.cover,
        toolbarAutoHideSeconds: 0,
      ),
      loadDocument: (chapter) async => NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          40,
          (index) => '第${index + 1}段 ${List.filled(32, '键盘翻页正文').join()}',
        ).join('\n'),
      ),
    );
    addTearDown(harness.store.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    // 整页快捷键此前挂在 NovelReaderInput 内部,而焦点被阅读页外层的 Focus 抢走,
    // 于是方向键 / 空格 / 回车对着整页全都没反应。
    int page() => int.parse(
          tester.getSemantics(find.byKey(const Key('novel-leaf-right'))).value,
        );
    final before = page();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(page(), greaterThan(before));

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(page(), greaterThan(before + 1));

    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsOneWidget);

    // Esc 仍然由同一个焦点节点收下,用来退出工具栏。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('novel-reader-bottom-bar')), findsNothing);
  });

  testWidgets('a turn after memory pressure recaptures its target frame',
      (tester) async {
    final controller = _StubNativeController();
    addTearDown(controller.dispose);
    final harness = await _readerHarness(
      controller,
      preferences: const NovelReaderPreferences(
        turnMode: NovelPageTurnMode.cover,
        toolbarAutoHideSeconds: 0,
      ),
    );
    addTearDown(harness.store.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    // 内存告警把相邻页帧清空。之后拖拽翻页时目标帧缺席,老实现只设 settlement:
    // 翻页层没有目标帧就不启动收尾动画,状态机永远回不到 idle。
    tester.binding.handleMemoryPressure();
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(700, 300));
    await gesture.moveTo(const Offset(300, 305));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.shownPages, contains(1));
  });

  testWidgets('dragging past the last page still crosses the chapter boundary',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final harness = await _readerHarness(
      null,
      useDefaultDocumentView: true,
      preferences: const NovelReaderPreferences(
        turnMode: NovelPageTurnMode.cover,
        toolbarAutoHideSeconds: 0,
      ),
      // 一章只有一页:章内已经翻不动了,拖拽必须回落成「翻到下一章」。
      loadDocument: (chapter) async => NovelDocument(
        format: NovelDocumentFormat.text,
        content: '${chapter.title}的正文',
      ),
    );
    addTearDown(harness.store.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    String statusChapter() => tester
        .widget<Text>(find.byKey(const Key('novel-status-chapter')))
        .data!;
    expect(statusChapter(), '第一章');

    final gesture = await tester.startGesture(const Offset(390, 400));
    await gesture.moveTo(const Offset(40, 404));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // 换章后的页帧预渲染是定时驱动的,pumpAndSettle 不会替它走完。
    for (var attempt = 0; attempt < 25; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(statusChapter(), '第二章');
  });

  testWidgets('scroll mode renders a scrollable chapter and tracks progress',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final harness = await _readerHarness(
      null,
      useDefaultDocumentView: true,
      preferences: const NovelReaderPreferences(
        turnMode: NovelPageTurnMode.scroll,
      ),
      loadDocument: (chapter) async => NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          40,
          (index) => '第${index + 1}段 ${List.filled(32, '滚动阅读正文').join()}',
        ).join('\n'),
      ),
    );
    addTearDown(harness.store.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    // 选了「上下滚动」就得真的有一个可滚的正文,而不是继续渲染分页视图。
    final scrollView = find.byKey(const Key('novel-native-scroll-view'));
    expect(scrollView, findsOneWidget);
    expect(find.byType(NovelNativePageView), findsNothing);

    await tester.drag(scrollView, const Offset(0, -600));
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scrollView, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position.pixels, greaterThan(0));
    expect(
      harness.store.progressFor('remote:s:n1')?.fraction ?? 0,
      greaterThan(0),
    );

    // 滚动模式下页码一直是 1/1（阅读页把 metrics 置空，状态栏拿缺省值
    // 充数）。现在改成章内可视百分比，并且要真的跟着滚动走。
    final pageLabel = tester.widget<Text>(
      find.byKey(const Key('novel-status-page')),
    );
    expect(pageLabel.data, isNot('1/1'));
    expect(pageLabel.data, endsWith('%'));
    expect(
      int.parse(pageLabel.data!.substring(0, pageLabel.data!.length - 1)),
      greaterThan(0),
    );
  });

  testWidgets('a chapter that paginates late still gets its page metrics',
      (tester) async {
    final controller = _FakeController(
      supportsPageFrames: true,
      pageCount: 5,
    )..paginationGate = Completer<void>();
    final harness = await _readerHarness(controller);
    addTearDown(harness.store.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();
    // 连兜底的等待上限都走完了（老实现的 20×50ms 轮询更是早就放弃）。
    await tester.pump(const Duration(seconds: 25));
    expect(
      tester.widget<Text>(find.byKey(const Key('novel-status-page'))).data,
      endsWith('%'),
    );

    controller.paginationGate!.complete();
    await tester.pumpAndSettle();

    // 排版真的完成以后页帧补刷一次，页码和翻页动画才有东西可用。
    expect(
      tester.widget<Text>(find.byKey(const Key('novel-status-page'))).data,
      '1/5',
    );
  });

  testWidgets('long pressing the page raises the selection bar',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final harness = await _readerHarness(
      null,
      useDefaultDocumentView: true,
      loadDocument: (chapter) async => NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          20,
          (index) => '第${index + 1}段 ${List.filled(24, '长按选词正文').join()}',
        ).join('\n'),
      ),
    );
    addTearDown(harness.store.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    // 原生渲染器根本没有选区入口，选择条 / 划线 / 笔记全是死路径。
    expect(find.byKey(const Key('novel-selection-bar')), findsNothing);

    await tester.longPressAt(const Offset(180, 200));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('novel-selection-bar')), findsOneWidget);

    // 点一下空白处就能退出选区。
    await tester.tapAt(const Offset(210, 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('novel-selection-bar')), findsNothing);
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

class _ImmediateSearchIndex extends NovelSearchIndex {
  _ImmediateSearchIndex()
      : super(rootDirectory: () async => Directory.systemTemp);

  @override
  Stream<NovelSearchEvent> search({
    required String bookKey,
    required String sourceFingerprint,
    required List<NovelChapter> chapters,
    required String query,
    required NovelSearchDocumentLoader loadCachedDocument,
    NovelSearchDocumentFetcher? fetchDocument,
    bool fetchMissing = false,
    NovelSearchCancellationToken? cancellation,
  }) async* {
    yield NovelSearchResultBatch([
      const NovelSearchResult(
        chapterId: 'c2',
        chapterTitle: '第二章',
        chapterIndex: 1,
        snippet: '前文目标后文',
        locator: NovelLocator(chapterId: 'c2', quote: '目标', fraction: .5),
      ),
    ]);
    yield const NovelSearchCompleted(resultCount: 1);
  }
}
