import 'dart:convert';

import 'package:dream_manga_reader/core/novel/reader/novel_page_turn_controller.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_page_turn_physics.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/features/novel/novel_page_turn_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final mode in NovelPageTurnMode.values) {
    testWidgets('${mode.name} selects its own render path', (tester) async {
      await tester.pumpWidget(
        _harness(
          mode: mode,
          state: const NovelTurnState(
            phase: NovelTurnPhase.dragging,
            direction: NovelTurnDirection.next,
            progress: .4,
          ),
        ),
      );

      expect(find.byKey(Key('novel-turn-${mode.name}')), findsOneWidget);
      expect(find.byKey(const Key('novel-turn-current')), findsOneWidget);
      expect(find.byKey(const Key('novel-turn-target')), findsOneWidget);
    });
  }

  testWidgets('committed settlement calls onCommitted exactly once',
      (tester) async {
    final commits = <NovelTurnDirection>[];
    final decision = const NovelTurnDecision(
      commit: true,
      direction: NovelTurnDirection.next,
      duration: Duration(milliseconds: 100),
    );
    final widget = _harness(
      state: const NovelTurnState(
        phase: NovelTurnPhase.settling,
        direction: NovelTurnDirection.next,
        progress: .35,
      ),
      decision: decision,
      onCommitted: commits.add,
    );

    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
    expect(commits, [NovelTurnDirection.next]);

    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
    expect(commits, [NovelTurnDirection.next]);
  });

  testWidgets('rollback settlement never calls onCommitted', (tester) async {
    final commits = <NovelTurnDirection>[];
    await tester.pumpWidget(
      _harness(
        state: const NovelTurnState(
          phase: NovelTurnPhase.settling,
          direction: NovelTurnDirection.next,
          progress: .2,
        ),
        decision: const NovelTurnDecision(
          commit: false,
          direction: NovelTurnDirection.next,
          duration: Duration(milliseconds: 80),
        ),
        onCommitted: commits.add,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(commits, isEmpty);
  });

  testWidgets('missing target frame keeps the current page visible',
      (tester) async {
    final commits = <NovelTurnDirection>[];
    await tester.pumpWidget(
      _harness(
        includeNext: false,
        state: const NovelTurnState(
          phase: NovelTurnPhase.settling,
          direction: NovelTurnDirection.next,
          progress: .5,
        ),
        decision: const NovelTurnDecision(
          commit: true,
          direction: NovelTurnDirection.next,
          duration: Duration(milliseconds: 80),
        ),
        onCommitted: commits.add,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('novel-turn-current')), findsOneWidget);
    expect(find.byKey(const Key('novel-turn-target')), findsNothing);
    expect(commits, isEmpty);
  });
}

Widget _harness({
  NovelPageTurnMode mode = NovelPageTurnMode.translate,
  NovelTurnState state = const NovelTurnState.idle(),
  NovelTurnDecision? decision,
  bool includeNext = true,
  ValueChanged<NovelTurnDirection>? onCommitted,
}) {
  return MaterialApp(
    home: SizedBox(
      width: 400,
      height: 700,
      child: NovelPageTurnSurface(
        mode: mode,
        state: state,
        settlement: decision,
        previousFrame: _frame(-1),
        currentFrame: _frame(0),
        nextFrame: includeNext ? _frame(1) : null,
        pageBackColor: const Color(0xfff5f0e4),
        onCommitted: onCommitted ?? (_) {},
      ),
    ),
  );
}

NovelPageFrame _frame(int pageIndex) {
  return NovelPageFrame(
    key: NovelPageKey(
      chapterId: 'chapter-1',
      pageIndex: pageIndex,
      layoutFingerprint: 'layout',
    ),
    viewport: const NovelViewport(width: 400, height: 700),
    bytes: base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
      'AAAADUlEQVR42mNk+M/wHwAF/gL+X1n0WQAAAABJRU5ErkJggg==',
    ),
  );
}
