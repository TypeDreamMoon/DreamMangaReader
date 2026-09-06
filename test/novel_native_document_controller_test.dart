import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_background_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_font_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_data.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/features/novel/novel_native_document_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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

  Future<Directory> fontSandbox() async {
    final directory = await Directory.systemTemp.createTemp('novel-native-font');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    return directory;
  }

  NovelDocument shortChapter() => NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          12,
          (index) => '第${index + 1}段 ${List.filled(20, '字体正文').join()}',
        ).join('\n'),
      );

  // 这两条走真实文件 IO(字体入库 / 解析),必须用 test() —— testWidgets 的
  // 假异步时钟不会推进真正的 IO Future。
  test('lays an imported font out under its registered family', () async {
    final support = await fontSandbox();
    final store = NovelFontStore(applicationSupportDirectory: () async =>
        Directory('${support.path}${Platform.pathSeparator}support'));
    final imported = await store.importFont(
      await File('${support.path}${Platform.pathSeparator}Reader.ttf')
          .writeAsBytes(_minimalTtf()),
    );
    final registeredFamilies = <String>[];
    final controller = NovelNativeDocumentController(
      fontRegistry: NovelFontRegistry(
        store: store,
        registerFace: (family, bytes) async => registeredFamilies.add(family),
      ),
    );
    addTearDown(controller.dispose);

    await controller.loadChapter(
      'chapter-1',
      shortChapter(),
      NovelReaderPreferences(fontFamily: imported.id),
    );
    final pagination = controller.ensurePagination(const Size(420, 720));

    expect(registeredFamilies, [imported.id]);
    expect(
      pagination!.pages.first.fragments.first.textStyle.fontFamily,
      imported.id,
    );
    expect((await controller.pageMetrics()).fontLoadFailed, isFalse);
  });

  test('reports an unusable imported font so the reader can fall back',
      () async {
    final support = await fontSandbox();
    final controller = NovelNativeDocumentController(
      fontRegistry: NovelFontRegistry(
        store: NovelFontStore(
          applicationSupportDirectory: () async => support,
        ),
        registerFace: (family, bytes) async {},
      ),
    );
    addTearDown(controller.dispose);

    await controller.loadChapter(
      'chapter-1',
      shortChapter(),
      NovelReaderPreferences(
        fontFamily: '${NovelFontIds.importedPrefix}${'b' * 64}',
      ),
    );
    final pagination = controller.ensurePagination(const Size(420, 720));

    // 排版退回内置字体,同时把失败报上去 —— 老实现两件事都不做。
    expect(pagination!.pages.first.fragments.first.textStyle.fontFamily, isNull);
    expect((await controller.pageMetrics()).fontLoadFailed, isTrue);
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

    // 纹理强度 / 背景铺法只影响像素，现在原生渲染器真的会画它们，所以它们也必须
    // 进页帧 key —— 否则调完滑块拿回来的还是上一套配色的位图。
    await controller.applyPreferences(
      const NovelReaderPreferences(
        brightness: .7,
        textureStrength: .9,
        backgroundFit: NovelBackgroundFit.tile,
      ),
    );
    controller.ensurePagination(const Size(420, 720));
    final textured = await tester.runAsync(() => controller.capturePage(0));

    expect(
      textured!.key.layoutFingerprint,
      isNot(dimmed.key.layoutFingerprint),
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

  testWidgets('signals when a chapter has actually been paginated',
      (tester) async {
    final controller = NovelNativeDocumentController();
    addTearDown(controller.dispose);
    var paginated = false;
    unawaited(controller.paginationReady.then((_) => paginated = true));
    await controller.loadChapter(
      'chapter-1',
      NovelDocument(
        format: NovelDocumentFormat.text,
        content: List.generate(
          40,
          (index) => '第${index + 1}段 ${List.filled(28, '排版信号正文').join()}',
        ).join('\n'),
      ),
      const NovelReaderPreferences(),
    );
    expect(controller.hasPagination, isFalse);
    await tester.pump();
    expect(paginated, isFalse);

    controller.paginationFor(const Size(420, 720));
    await tester.pump();

    expect(controller.hasPagination, isTrue);
    expect(paginated, isTrue);

    // 改设置 = 重排，信号重新武装，不能拿上一轮的结果充数。
    await controller.applyPreferences(
      const NovelReaderPreferences(fontSize: 24),
    );
    expect(controller.hasPagination, isFalse);
    var repaginated = false;
    unawaited(controller.paginationReady.then((_) => repaginated = true));
    await tester.pump();
    expect(repaginated, isFalse);

    controller.paginationFor(const Size(420, 720));
    await tester.pump();
    expect(repaginated, isTrue);
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

  group('background and brightness reach the native renderer', () {
    late Directory directory;
    late NovelBackgroundStore store;

    final document = NovelDocument(
      format: NovelDocumentFormat.text,
      content: List.generate(
        24,
        (index) => '\u7b2c${index + 1}\u6bb5 ${List.filled(24, '\u80cc\u666f\u6e32\u67d3\u6b63\u6587').join()}',
      ).join('\n'),
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('dmr-novel-background');
      store = NovelBackgroundStore(
        applicationSupportDirectory: () async => directory,
      );
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    Future<NovelNativeDocumentController> open(
      NovelReaderPreferences preferences,
    ) async {
      final controller = NovelNativeDocumentController(backgroundStore: store);
      await controller.loadChapter('chapter-1', document, preferences);
      // 截页帧要立刻有版面，走同步的 ensurePagination，别等 build 后的那次异步排版。
      controller.ensurePagination(const Size(420, 720));
      return controller;
    }

    Future<Uint8List> raster(
      WidgetTester tester,
      NovelReaderPreferences preferences,
    ) async {
      final bytes = await tester.runAsync(() async {
        final controller = await open(preferences);
        try {
          return (await controller.capturePage(0))!.bytes;
        } finally {
          controller.dispose();
        }
      });
      return bytes!;
    }

    testWidgets('texture strength and brightness change what gets painted',
        (tester) async {
      // 五项背景设置原本只有已废弃的 WebView 控制器消费，原生渲染器只画主题纯色，
      // 拖动滑块屏幕上没任何反应。
      final withoutTexture = await raster(
        tester,
        const NovelReaderPreferences(
          theme: NovelReaderTheme.paper,
          textureStrength: 0,
        ),
      );
      final withTexture = await raster(
        tester,
        const NovelReaderPreferences(
          theme: NovelReaderTheme.paper,
          textureStrength: 1,
        ),
      );
      final dimmed = await raster(
        tester,
        const NovelReaderPreferences(
          theme: NovelReaderTheme.paper,
          textureStrength: 0,
          brightness: .6,
        ),
      );

      expect(withTexture, isNot(withoutTexture));
      expect(dimmed, isNot(withoutTexture));
    });

    testWidgets('an imported background is laid out by the chosen fit',
        (tester) async {
      final imported = await tester.runAsync(() async {
        final source = File('${directory.path}${Platform.pathSeparator}bg.png');
        final picture = img.Image(width: 16, height: 16);
        for (var y = 0; y < 16; y++) {
          for (var x = 0; x < 16; x++) {
            picture.setPixelRgba(x, y, x * 16, y * 16, 128, 255);
          }
        }
        await source.writeAsBytes(img.encodePng(picture));
        return store.importImage(source);
      });

      final cropped = await raster(
        tester,
        NovelReaderPreferences(
          backgroundAssetId: imported!.id,
          backgroundFit: NovelBackgroundFit.crop,
        ),
      );
      final tiled = await raster(
        tester,
        NovelReaderPreferences(
          backgroundAssetId: imported.id,
          backgroundFit: NovelBackgroundFit.tile,
        ),
      );

      expect(cropped, isNot(tiled));
    });

    testWidgets('a background that will not decode falls back to the theme',
        (tester) async {
      final fallbacks = <void>[];
      final controller = await tester.runAsync(() async {
        final value = NovelNativeDocumentController(backgroundStore: store);
        value.onBackgroundFallback = () => fallbacks.add(null);
        await value.loadChapter(
          'chapter-1',
          document,
          NovelReaderPreferences(backgroundAssetId: 'imported:${'a' * 64}'),
        );
        return value;
      });
      addTearDown(controller!.dispose);

      // 没有这个图就该回到主题底色，并告诉阅读页把这项设置清掉 ——
      // 原生渲染路径以前压根没人发过这个回调。
      expect(fallbacks, hasLength(1));
      expect(controller.pageBackground, isNull);
    });
  });

  group('selection and highlights', () {
    final document = NovelDocument(
      format: NovelDocumentFormat.text,
      content: List.generate(
        12,
        (index) => '\u7b2c${index + 1}\u6bb5 ${List.filled(20, '\u5212\u7ebf\u9009\u8bcd\u6b63\u6587').join()}',
      ).join('\n'),
    );

    Future<NovelNativeDocumentController> open() async {
      final controller = NovelNativeDocumentController();
      await controller.loadChapter(
        'chapter-1',
        document,
        const NovelReaderPreferences(),
      );
      // 选区 / 高亮都要拿现成的版面来映射，走同步的 ensurePagination，
      // 而不是 build 期间「只读缓存、算完再通知」的 paginationFor。
      controller.ensurePagination(const Size(420, 720));
      return controller;
    }

    testWidgets('stored annotations become paintable ranges', (tester) async {
      final controller = await open();
      addTearDown(controller.dispose);
      final blockId =
          controller.pagination!.pages.first.fragments.first.blockId;

      final unresolved = await controller.applyAnnotations([
        NovelAnnotation.create(
          bookKey: 'book',
          range: NovelAnnotationRange(
            start: NovelLocator(
              chapterId: 'chapter-1',
              blockId: blockId,
              charOffset: 2,
            ),
            end: NovelLocator(
              chapterId: 'chapter-1',
              blockId: blockId,
              charOffset: 9,
            ),
            quote: '\u5212\u7ebf',
          ),
          colorId: 'yellow',
          createdAt: 1,
        ),
        NovelAnnotation.create(
          bookKey: 'book',
          range: const NovelAnnotationRange(
            start: NovelLocator(
              chapterId: 'chapter-1',
              blockId: 'dmr-does-not-exist',
              charOffset: 0,
            ),
            end: NovelLocator(
              chapterId: 'chapter-1',
              blockId: 'dmr-does-not-exist',
              charOffset: 3,
            ),
            quote: '\u4e22\u4e86',
          ),
          colorId: 'green',
          createdAt: 2,
        ),
      ]);

      // 老实现 applyAnnotations 只把注记存进一个没人读的字段，并且总是报「没有失效」。
      expect(controller.highlights, hasLength(1));
      expect(controller.highlights.single.blockId, blockId);
      expect(controller.highlights.single.start, 2);
      expect(controller.highlights.single.end, 9);
      expect(unresolved, hasLength(1));
    });

    testWidgets('a long press selects a word and the drag extends it',
        (tester) async {
      final controller = await open();
      addTearDown(controller.dispose);
      final selections = <NovelSelection?>[];
      controller.onSelectionChanged = selections.add;

      expect(controller.beginSelection(const Offset(120, 40)), isTrue);
      final anchored = controller.currentSelection;
      expect(anchored, isNotNull);
      expect(anchored!.text, isNotEmpty);
      expect(anchored.start.blockId, isNotNull);
      expect(controller.highlights, isNotEmpty);

      controller.updateSelection(const Offset(300, 120));
      final extended = controller.currentSelection!;
      expect(extended.text.length, greaterThan(anchored.text.length));

      controller.commitSelection();
      expect(selections, hasLength(1));
      expect(selections.single!.text, extended.text);
      expect(selections.single!.rect, isNotNull);

      await controller.clearSelection();
      expect(controller.hasSelection, isFalse);
      expect(controller.highlights, isEmpty);
      expect(selections.last, isNull);
    });

    testWidgets('a highlight actually shows up in the painted page',
        (tester) async {
      final plain = await tester.runAsync(() async {
        final controller = await open();
        try {
          return (await controller.capturePage(0))!.bytes;
        } finally {
          controller.dispose();
        }
      });
      final marked = await tester.runAsync(() async {
        final controller = await open();
        try {
          final blockId =
              controller.pagination!.pages.first.fragments.first.blockId;
          await controller.applyAnnotations([
            NovelAnnotation.create(
              bookKey: 'book',
              range: NovelAnnotationRange(
                start: NovelLocator(
                  chapterId: 'chapter-1',
                  blockId: blockId,
                  charOffset: 0,
                ),
                end: NovelLocator(
                  chapterId: 'chapter-1',
                  blockId: blockId,
                  charOffset: 12,
                ),
                quote: '\u5212\u7ebf',
              ),
              colorId: 'yellow',
              createdAt: 1,
            ),
          ]);
          return (await controller.capturePage(0))!.bytes;
        } finally {
          controller.dispose();
        }
      });

      expect(marked, isNot(plain));
    });
  });
}

/// 结构上合法、但没有轮廓数据的最小 TTF：只用来走通导入与注册路径。
List<int> _minimalTtf() {
  const tags = <String>[
    'OS/2',
    'cmap',
    'glyf',
    'head',
    'hhea',
    'hmtx',
    'loca',
    'maxp',
    'name',
    'post',
  ];
  final directoryEnd = 12 + tags.length * 16;
  final bytes = <int>[
    0x00, 0x01, 0x00, 0x00,
    0x00, tags.length,
    0x00, 0x00,
    0x00, 0x00,
    0x00, 0x00,
  ];
  var offset = directoryEnd;
  for (final tag in tags) {
    bytes.addAll(tag.codeUnits);
    bytes.addAll([0, 0, 0, 0]);
    bytes.addAll([
      (offset >> 24) & 0xff,
      (offset >> 16) & 0xff,
      (offset >> 8) & 0xff,
      offset & 0xff,
    ]);
    bytes.addAll([0, 0, 0, 16]);
    offset += 16;
  }
  bytes.addAll(List<int>.filled(tags.length * 16, 0));
  return bytes;
}
