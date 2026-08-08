import 'dart:ui' as ui;

import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_page_turn_controller.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_page_turn_physics.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_paginator.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_render_document.dart';
import 'package:dream_manga_reader/features/novel/novel_native_page_turn_surface.dart';
import 'package:dream_manga_reader/features/novel/novel_native_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NovelPaginationResult pagination(Size size) => NovelPaginator.paginate(
        document: NovelRenderDocumentParser.parse(
          NovelDocument(
            format: NovelDocumentFormat.text,
            content: List.generate(
              30,
              (index) => '第${index + 1}段 ${List.filled(36, '翻页正文').join()}',
            ).join('\n'),
          ),
        ),
        viewport: size,
        style: const NovelPageStyle(
          fontSize: 18,
          lineHeight: 1.6,
          paragraphSpacing: 10,
          firstLineIndent: 2,
          pagePadding: EdgeInsets.fromLTRB(24, 28, 24, 32),
        ),
      );

  Widget harness({
    required Size size,
    required NovelPaginationResult pagination,
    required NovelTurnState state,
    NovelTurnDecision? settlement,
    ValueChanged<NovelTurnDirection>? onCommitted,
  }) {
    return MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: size,
          child: NovelNativePageTurnSurface(
            pagination: pagination,
            currentSpreadIndex: 0,
            state: state,
            settlement: settlement,
            canvasColor: const Color(0xffd8d1bf),
            pageColor: const Color(0xfff5efde),
            textColor: const Color(0xff24221e),
            onCommitted: onCommitted ?? (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('curl geometry follows the live drag contact point',
      (tester) async {
    const size = Size(400, 700);
    final result = pagination(size);
    await tester.pumpWidget(harness(
      size: size,
      pagination: result,
      state: const NovelTurnState(
        phase: NovelTurnPhase.dragging,
        direction: NovelTurnDirection.next,
        progress: .4,
        touchOrigin: Offset(385, 610),
        touchPosition: Offset(238, 520),
        viewport: size,
      ),
    ));

    expect(find.byKey(const Key('novel-native-turn-target')), findsOneWidget);
    expect(find.byKey(const Key('novel-native-turn-current')), findsOneWidget);
    expect(find.byKey(const Key('novel-native-page-back')), findsOneWidget);
    expect(find.byKey(const Key('novel-native-fold-shadow')), findsOneWidget);
    expect(find.byKey(const Key('novel-native-curl-sheet')), findsOneWidget);
    expect(find.byKey(const Key('novel-native-curl-overlay')), findsNothing);
    final sheet = tester.widget<CustomPaint>(
      find.byKey(const Key('novel-native-curl-sheet')),
    );
    expect(sheet.painter.runtimeType.toString(), 'PageCurlPainter');
    expect(
      tester.getRect(find.byKey(const Key('novel-native-curl-sheet'))),
      result.leafRects.single,
    );
    final clip = tester.widget<ClipPath>(
      find.byKey(const Key('novel-native-current-curl-clip')),
    );
    final visiblePath = clip.clipper!.getClip(size);
    expect(visiblePath.contains(const Offset(20, 20)), isTrue);
    expect(visiblePath.contains(const Offset(390, 610)), isFalse);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('wide next turn curls only the right book leaf', (tester) async {
    const size = Size(1180, 760);
    final result = pagination(size);
    await tester.pumpWidget(harness(
      size: size,
      pagination: result,
      state: NovelTurnState(
        phase: NovelTurnPhase.dragging,
        direction: NovelTurnDirection.next,
        progress: .35,
        touchOrigin: result.leafRects[1].bottomRight,
        touchPosition: result.leafRects[1].center,
        viewport: size,
      ),
    ));

    expect(
      tester.getRect(find.byKey(const Key('novel-native-curl-sheet'))),
      result.leafRects[1],
    );
    expect(find.byKey(const Key('novel-native-curl-mirrored')), findsNothing);
  });

  testWidgets('wide previous turn curls only the left book leaf',
      (tester) async {
    const size = Size(1180, 760);
    final result = pagination(size);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.fromSize(
          size: size,
          child: NovelNativePageTurnSurface(
            pagination: result,
            currentSpreadIndex: 1,
            state: NovelTurnState(
              phase: NovelTurnPhase.dragging,
              direction: NovelTurnDirection.previous,
              progress: .3,
              touchOrigin: result.leafRects[0].bottomLeft,
              touchPosition: result.leafRects[0].center,
              viewport: size,
            ),
            canvasColor: const Color(0xffd8d1bf),
            pageColor: const Color(0xfff5efde),
            textColor: const Color(0xff24221e),
            onCommitted: (_) {},
          ),
        ),
      ),
    );

    expect(
      tester.getRect(find.byKey(const Key('novel-native-curl-sheet'))),
      result.leafRects[0],
    );
    expect(
      find.byKey(const Key('novel-native-curl-mirrored')),
      findsOneWidget,
    );
  });

  testWidgets('settled native curl commits exactly once', (tester) async {
    const size = Size(400, 700);
    final result = pagination(size);
    final commits = <NovelTurnDirection>[];
    final widget = harness(
      size: size,
      pagination: result,
      state: const NovelTurnState(
        phase: NovelTurnPhase.settling,
        direction: NovelTurnDirection.next,
        progress: .3,
        touchOrigin: Offset(390, 620),
        touchPosition: Offset(280, 570),
        viewport: size,
      ),
      settlement: const NovelTurnDecision(
        commit: true,
        direction: NovelTurnDirection.next,
        duration: Duration(milliseconds: 90),
      ),
      onCommitted: commits.add,
    );

    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
    expect(commits, [NovelTurnDirection.next]);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
    expect(commits, [NovelTurnDirection.next]);
  });

  testWidgets('settlement starts at the final live drag geometry',
      (tester) async {
    const size = Size(400, 580);
    final result = pagination(size);
    const origin = Offset(385, 520);
    const release = Offset(250, 400);
    const dragging = NovelTurnState(
      phase: NovelTurnPhase.dragging,
      direction: NovelTurnDirection.next,
      progress: .34,
      touchOrigin: origin,
      touchPosition: release,
      viewport: size,
    );

    await tester.pumpWidget(harness(
      size: size,
      pagination: result,
      state: dragging,
    ));
    final beforePainter = tester
        .widget<CustomPaint>(
          find.byKey(const Key('novel-native-curl-sheet')),
        )
        .painter as dynamic;
    final beforeCylinder = beforePainter.nullableCylinder as dynamic;

    await tester.pumpWidget(harness(
      size: size,
      pagination: result,
      state: const NovelTurnState(
        phase: NovelTurnPhase.settling,
        direction: NovelTurnDirection.next,
        progress: .34,
        touchOrigin: origin,
        touchPosition: release,
        viewport: size,
      ),
      settlement: const NovelTurnDecision(
        commit: true,
        direction: NovelTurnDirection.next,
        duration: Duration(milliseconds: 180),
      ),
    ));
    final afterPainter = tester
        .widget<CustomPaint>(
          find.byKey(const Key('novel-native-curl-sheet')),
        )
        .painter as dynamic;
    final afterCylinder = afterPainter.nullableCylinder as dynamic;

    expect(afterCylinder.center.x, closeTo(beforeCylinder.center.x, .001));
    expect(afterCylinder.center.y, closeTo(beforeCylinder.center.y, .001));
  });

  testWidgets('uses pre-rasterized spreads instead of repainting page text',
      (tester) async {
    const size = Size(400, 580);
    final result = pagination(size);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfff5efde),
    );
    final picture = recorder.endRecording();
    final image = (await tester.runAsync(
      () => picture.toImage(size.width.toInt(), size.height.toInt()),
    ))!;
    picture.dispose();
    addTearDown(image.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.fromSize(
          size: size,
          child: NovelNativePageTurnSurface(
            pagination: result,
            currentSpreadIndex: 0,
            state: const NovelTurnState(
              phase: NovelTurnPhase.dragging,
              direction: NovelTurnDirection.next,
              progress: .3,
              touchOrigin: Offset(385, 520),
              touchPosition: Offset(260, 480),
              viewport: size,
            ),
            currentPageImage: image,
            nextPageImage: image,
            canvasColor: const Color(0xffd8d1bf),
            pageColor: const Color(0xfff5efde),
            textColor: const Color(0xff24221e),
            onCommitted: (_) {},
          ),
        ),
      ),
    );

    expect(
        find.byKey(const Key('novel-native-cached-current')), findsOneWidget);
    expect(find.byKey(const Key('novel-native-cached-target')), findsOneWidget);
    expect(find.byType(NovelNativePageView), findsNothing);
  });
}
