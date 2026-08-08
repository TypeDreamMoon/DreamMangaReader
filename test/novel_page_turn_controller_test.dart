import 'dart:ui';

import 'package:dream_manga_reader/core/novel/reader/novel_page_turn_controller.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_page_turn_physics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const viewport = Size(1000, 1600);

  group('NovelPageTurnController', () {
    test('locks a horizontal next-page drag after touch slop', () {
      final controller = NovelPageTurnController();

      controller.begin(const Offset(900, 500), viewport);
      controller.update(
        const Offset(600, 505),
        elapsed: const Duration(milliseconds: 180),
      );

      expect(controller.state.phase, NovelTurnPhase.dragging);
      expect(controller.state.direction, NovelTurnDirection.next);
      expect(controller.state.progress, closeTo(.3, .001));
      expect(controller.state.touchOrigin, const Offset(900, 500));
      expect(controller.state.touchPosition, const Offset(600, 505));
      expect(controller.state.viewport, viewport);
    });

    test('locks a horizontal previous-page drag in the other direction', () {
      final controller = NovelPageTurnController();

      controller.begin(const Offset(100, 500), viewport);
      controller.update(
        const Offset(360, 500),
        elapsed: const Duration(milliseconds: 150),
      );

      expect(controller.state.phase, NovelTurnPhase.dragging);
      expect(controller.state.direction, NovelTurnDirection.previous);
      expect(controller.state.progress, closeTo(.26, .001));
    });

    test('keeps the locked direction when the pointer crosses its origin', () {
      final controller = NovelPageTurnController();

      controller.begin(const Offset(500, 500), viewport);
      controller.update(
        const Offset(300, 500),
        elapsed: const Duration(milliseconds: 100),
      );
      controller.update(
        const Offset(550, 500),
        elapsed: const Duration(milliseconds: 200),
      );

      expect(controller.state.direction, NovelTurnDirection.next);
      expect(controller.state.progress, 0);
    });

    test('commits immediately when a locked drag reaches the fold angle limit',
        () {
      final controller = NovelPageTurnController();

      controller.begin(const Offset(900, 1200), viewport);
      controller.update(
        const Offset(760, 1190),
        elapsed: const Duration(milliseconds: 90),
      );
      final decision = controller.update(
        const Offset(640, 700),
        elapsed: const Duration(milliseconds: 180),
      );

      expect(decision, isNotNull);
      expect(decision!.commit, isTrue);
      expect(decision.direction, NovelTurnDirection.next);
      expect(controller.state.phase, NovelTurnPhase.settling);
    });

    test('rejects a vertical gesture instead of turning a page', () {
      final controller = NovelPageTurnController();

      controller.begin(const Offset(500, 500), viewport);
      controller.update(
        const Offset(505, 700),
        elapsed: const Duration(milliseconds: 100),
      );

      expect(controller.state.phase, NovelTurnPhase.idle);
      expect(controller.end(velocity: const Offset(0, 1200)), isNull);
    });

    test('sub-slop release returns to idle and accepts the next gesture', () {
      final controller = NovelPageTurnController();

      controller.begin(const Offset(500, 500), viewport);
      controller.update(
        const Offset(506, 503),
        elapsed: const Duration(milliseconds: 80),
      );
      expect(controller.state.phase, NovelTurnPhase.tracking);

      expect(controller.end(velocity: Offset.zero), isNull);
      expect(controller.state.phase, NovelTurnPhase.idle);

      controller.begin(const Offset(900, 500), viewport);
      expect(controller.state.phase, NovelTurnPhase.tracking);
      controller.update(
        const Offset(700, 500),
        elapsed: const Duration(milliseconds: 100),
      );
      expect(controller.state.phase, NovelTurnPhase.dragging);
    });

    test('commits once drag distance reaches twenty eight percent', () {
      final controller = NovelPageTurnController();
      controller.begin(const Offset(900, 500), viewport);
      controller.update(
        const Offset(620, 500),
        elapsed: const Duration(milliseconds: 250),
      );

      final decision = controller.end(velocity: Offset.zero)!;

      expect(decision.commit, isTrue);
      expect(decision.direction, NovelTurnDirection.next);
      expect(decision.duration.inMilliseconds, inInclusiveRange(140, 280));
      expect(controller.state.phase, NovelTurnPhase.settling);
    });

    test('commits a short drag when release velocity is fast and aligned', () {
      final controller = NovelPageTurnController();
      controller.begin(const Offset(900, 500), viewport);
      controller.update(
        const Offset(820, 500),
        elapsed: const Duration(milliseconds: 80),
      );

      final decision = controller.end(
        velocity: const Offset(-900, 0),
      )!;

      expect(decision.commit, isTrue);
      expect(decision.direction, NovelTurnDirection.next);
    });

    test('does not commit when fling velocity opposes the drag direction', () {
      final controller = NovelPageTurnController();
      controller.begin(const Offset(900, 500), viewport);
      controller.update(
        const Offset(820, 500),
        elapsed: const Duration(milliseconds: 80),
      );

      final decision = controller.end(
        velocity: const Offset(900, 0),
      )!;

      expect(decision.commit, isFalse);
      expect(decision.duration, const Duration(milliseconds: 180));
    });

    test('rolls a short slow drag back without entering commit phase', () {
      final controller = NovelPageTurnController();
      controller.begin(const Offset(900, 500), viewport);
      controller.update(
        const Offset(780, 500),
        elapsed: const Duration(milliseconds: 250),
      );

      final decision = controller.end(velocity: Offset.zero)!;
      expect(decision.commit, isFalse);

      controller.completeSettlement();

      expect(controller.state.phase, NovelTurnPhase.idle);
    });

    test('commit becomes visible only after settlement completes', () {
      final controller = NovelPageTurnController();
      controller.begin(const Offset(900, 500), viewport);
      controller.update(
        const Offset(500, 500),
        elapsed: const Duration(milliseconds: 200),
      );

      final decision = controller.end(velocity: Offset.zero)!;
      expect(decision.commit, isTrue);
      expect(controller.state.phase, NovelTurnPhase.settling);

      controller.completeSettlement();
      expect(controller.state.phase, NovelTurnPhase.committing);

      controller.completeCommit();
      expect(controller.state.phase, NovelTurnPhase.idle);
    });

    test('committed direction is consumable once only after settlement', () {
      final controller = NovelPageTurnController();
      controller.begin(const Offset(900, 500), viewport);
      controller.update(
        const Offset(500, 500),
        elapsed: const Duration(milliseconds: 200),
      );

      final decision = controller.end(velocity: Offset.zero)!;
      expect(decision.commit, isTrue);
      expect(controller.consumeCommittedDirection(), isNull);

      controller.completeSettlement();

      expect(
        controller.consumeCommittedDirection(),
        NovelTurnDirection.next,
      );
      expect(controller.consumeCommittedDirection(), isNull);
    });

    test('rollback never produces a committed direction', () {
      final controller = NovelPageTurnController();
      controller.begin(const Offset(900, 500), viewport);
      controller.update(
        const Offset(780, 500),
        elapsed: const Duration(milliseconds: 200),
      );

      final decision = controller.end(velocity: Offset.zero)!;
      expect(decision.commit, isFalse);
      expect(controller.consumeCommittedDirection(), isNull);

      controller.completeSettlement();

      expect(controller.consumeCommittedDirection(), isNull);
      expect(controller.state.phase, NovelTurnPhase.idle);
    });

    test('pointer cancellation returns directly to idle', () {
      final controller = NovelPageTurnController();
      controller.begin(const Offset(900, 500), viewport);
      controller.update(
        const Offset(700, 500),
        elapsed: const Duration(milliseconds: 100),
      );

      controller.cancel();

      expect(controller.state.phase, NovelTurnPhase.idle);
      expect(controller.end(velocity: Offset.zero), isNull);
    });

    test('busy controller keeps at most one queued discrete command', () {
      final controller = NovelPageTurnController();

      final first = controller.startDiscrete(NovelTurnDirection.next);
      expect(first.commit, isTrue);
      expect(controller.state.phase, NovelTurnPhase.settling);

      expect(controller.queueDiscrete(NovelTurnDirection.previous), isTrue);
      expect(controller.queueDiscrete(NovelTurnDirection.next), isFalse);

      controller.completeSettlement();
      controller.completeCommit();

      expect(controller.takeQueuedDirection(), NovelTurnDirection.previous);
      expect(controller.takeQueuedDirection(), isNull);
    });

    test('discrete turn starts from the supplied tap position', () {
      final controller = NovelPageTurnController();
      controller.setDiscreteOrigin(const Offset(940, 1320), viewport);

      controller.startDiscrete(NovelTurnDirection.next);

      expect(controller.state.touchOrigin, const Offset(940, 1320));
      expect(controller.state.touchPosition, const Offset(940, 1320));
      expect(controller.state.viewport, viewport);
    });

    test('keyboard discrete turn uses a lower page corner by default', () {
      final controller = NovelPageTurnController();

      controller.startDiscrete(NovelTurnDirection.previous);

      expect(controller.state.touchOrigin.dx, 0);
      expect(controller.state.touchOrigin.dy, greaterThan(0));
      expect(controller.state.viewport.width, greaterThan(0));
    });
  });

  group('NovelPageTurnPhysics', () {
    test('settle duration shrinks as less distance remains', () {
      const physics = NovelPageTurnPhysics();

      final early = physics.commitDuration(progress: .1, velocity: 0);
      final late = physics.commitDuration(progress: .9, velocity: 0);

      expect(early, greaterThan(late));
      expect(early, lessThanOrEqualTo(physics.maxCommitDuration));
      expect(late, greaterThanOrEqualTo(physics.minCommitDuration));
    });
  });
}
