import 'package:dream_manga_reader/core/novel/reader/novel_page_turn_controller.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_page_turn_physics.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_input.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('touch drag drives the shared page turn controller',
      (tester) async {
    final decisions = <NovelTurnDecision>[];
    await tester.pumpWidget(_harness(onDecision: decisions.add));

    final gesture = await tester.startGesture(
      const Offset(500, 300),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(const Offset(180, 305));
    await gesture.up();

    expect(decisions, hasLength(1));
    expect(decisions.single.commit, isTrue);
    expect(decisions.single.direction, NovelTurnDirection.next);
  });

  testWidgets('mouse drag uses the same direction and commit rules',
      (tester) async {
    final decisions = <NovelTurnDecision>[];
    await tester.pumpWidget(_harness(onDecision: decisions.add));

    final gesture = await tester.startGesture(
      const Offset(100, 300),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(const Offset(420, 300));
    await gesture.up();

    expect(decisions.single.commit, isTrue);
    expect(decisions.single.direction, NovelTurnDirection.previous);
  });

  testWidgets('vertical gesture is rejected without a page decision',
      (tester) async {
    final decisions = <NovelTurnDecision>[];
    final controller = NovelPageTurnController();
    await tester.pumpWidget(
      _harness(controller: controller, onDecision: decisions.add),
    );

    final gesture = await tester.startGesture(const Offset(300, 100));
    await gesture.moveTo(const Offset(305, 450));
    await gesture.up();

    expect(decisions, isEmpty);
    expect(controller.state.phase, NovelTurnPhase.idle);
  });

  testWidgets('tap zones are previous center controls and next',
      (tester) async {
    final directions = <NovelTurnDirection>[];
    var toggles = 0;
    await tester.pumpWidget(
      _harness(
        onDiscrete: directions.add,
        onToggleControls: () => toggles++,
      ),
    );

    await tester.tapAt(const Offset(120, 300));
    await tester.tapAt(const Offset(400, 300));
    await tester.tapAt(const Offset(680, 300));

    expect(directions, [
      NovelTurnDirection.previous,
      NovelTurnDirection.next,
    ]);
    expect(toggles, 1);
  });

  testWidgets('single-hand mode turns either edge into next page',
      (tester) async {
    final directions = <NovelTurnDirection>[];
    await tester.pumpWidget(
      _harness(singleHandNext: true, onDiscrete: directions.add),
    );

    await tester.tapAt(const Offset(120, 300));
    await tester.tapAt(const Offset(680, 300));

    expect(directions, [
      NovelTurnDirection.next,
      NovelTurnDirection.next,
    ]);
  });

  testWidgets('wheel commands are throttled and preserve direction',
      (tester) async {
    final directions = <NovelTurnDirection>[];
    await tester.pumpWidget(_harness(onDiscrete: directions.add));

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(300, 300),
        scrollDelta: Offset(0, 80),
      ),
    );
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(300, 300),
        scrollDelta: Offset(0, 80),
      ),
    );
    await tester.pump(const Duration(milliseconds: 260));
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(300, 300),
        scrollDelta: Offset(0, -80),
      ),
    );

    expect(directions, [
      NovelTurnDirection.next,
      NovelTurnDirection.previous,
    ]);
  });

  testWidgets('keyboard paging and center controls use shortcuts',
      (tester) async {
    final directions = <NovelTurnDirection>[];
    var toggles = 0;
    await tester.pumpWidget(
      _harness(
        onDiscrete: directions.add,
        onToggleControls: () => toggles++,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(directions, [
      NovelTurnDirection.previous,
      NovelTurnDirection.next,
    ]);
    expect(toggles, 1);
  });

  testWidgets('blocked input ignores selection and sheet interactions',
      (tester) async {
    final directions = <NovelTurnDirection>[];
    await tester.pumpWidget(
      _harness(blocked: true, onDiscrete: directions.add),
    );

    await tester.tapAt(const Offset(680, 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);

    expect(directions, isEmpty);
  });
}

Widget _harness({
  NovelPageTurnController? controller,
  bool blocked = false,
  bool singleHandNext = false,
  ValueChanged<NovelTurnDecision>? onDecision,
  ValueChanged<NovelTurnDirection>? onDiscrete,
  VoidCallback? onToggleControls,
}) {
  return MaterialApp(
    home: Center(
      child: SizedBox(
        width: 600,
        height: 500,
        child: NovelReaderInput(
          controller: controller ?? NovelPageTurnController(),
          blocked: blocked,
          singleHandNext: singleHandNext,
          onStateChanged: () {},
          onDecision: onDecision ?? (_) {},
          onDiscrete: onDiscrete ?? (_) {},
          onToggleControls: onToggleControls ?? () {},
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    ),
  );
}
