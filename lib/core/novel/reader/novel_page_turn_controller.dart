import 'dart:ui';

import 'novel_page_turn_physics.dart';

enum NovelTurnPhase { idle, tracking, dragging, settling, committing }

class NovelTurnState {
  const NovelTurnState({
    required this.phase,
    this.direction,
    this.progress = 0,
    this.dragOffset = Offset.zero,
    this.touchOrigin = Offset.zero,
    this.touchPosition = Offset.zero,
    this.viewport = Size.zero,
  });

  const NovelTurnState.idle()
      : phase = NovelTurnPhase.idle,
        direction = null,
        progress = 0,
        dragOffset = Offset.zero,
        touchOrigin = Offset.zero,
        touchPosition = Offset.zero,
        viewport = Size.zero;

  final NovelTurnPhase phase;
  final NovelTurnDirection? direction;
  final double progress;
  final Offset dragOffset;
  final Offset touchOrigin;
  final Offset touchPosition;
  final Size viewport;
}

class NovelTurnDecision {
  const NovelTurnDecision({
    required this.commit,
    required this.direction,
    required this.duration,
  });

  final bool commit;
  final NovelTurnDirection direction;
  final Duration duration;
}

class NovelPageTurnController {
  NovelPageTurnController({
    this.physics = const NovelPageTurnPhysics(),
  });

  final NovelPageTurnPhysics physics;

  NovelTurnState _state = const NovelTurnState.idle();
  Offset _start = Offset.zero;
  Size _viewport = Size.zero;
  bool _pointerActive = false;
  bool _settlementCommits = false;
  NovelTurnDirection? _committedDirection;
  NovelTurnDirection? _queuedDirection;
  Offset? _discreteOrigin;

  NovelTurnState get state => _state;

  void begin(Offset position, Size viewport) {
    if (_state.phase != NovelTurnPhase.idle ||
        !viewport.width.isFinite ||
        viewport.width <= 0 ||
        !viewport.height.isFinite ||
        viewport.height <= 0) {
      return;
    }
    _start = position;
    _viewport = viewport;
    _pointerActive = true;
    _settlementCommits = false;
    _state = NovelTurnState(
      phase: NovelTurnPhase.tracking,
      touchOrigin: position,
      touchPosition: position,
      viewport: viewport,
    );
  }

  NovelTurnDecision? update(Offset position, {required Duration elapsed}) {
    if (!_pointerActive) return null;
    final delta = position - _start;
    if (_state.phase == NovelTurnPhase.tracking) {
      if (physics.shouldRejectAsVertical(dx: delta.dx, dy: delta.dy)) {
        _pointerActive = false;
        _state = const NovelTurnState.idle();
        return null;
      }
      if (!physics.shouldLockHorizontal(dx: delta.dx, dy: delta.dy)) {
        return null;
      }
    }
    if (_state.phase != NovelTurnPhase.tracking &&
        _state.phase != NovelTurnPhase.dragging) {
      return null;
    }
    final direction = _state.phase == NovelTurnPhase.dragging
        ? _state.direction!
        : delta.dx < 0
            ? NovelTurnDirection.next
            : NovelTurnDirection.previous;
    final alignedDx = switch (direction) {
      NovelTurnDirection.next => delta.dx.clamp(-_viewport.width, 0.0),
      NovelTurnDirection.previous => delta.dx.clamp(0.0, _viewport.width),
    };
    final progress = (alignedDx.abs() / _viewport.width).clamp(0.0, 1.0);
    _state = NovelTurnState(
      phase: NovelTurnPhase.dragging,
      direction: direction,
      progress: progress,
      dragOffset: Offset(alignedDx, delta.dy),
      touchOrigin: _start,
      touchPosition: position,
      viewport: _viewport,
    );
    if (physics.reachesFoldAngleLimit(
      progress: progress,
      dx: alignedDx,
      dy: delta.dy,
      viewportWidth: _viewport.width,
      viewportHeight: _viewport.height,
    )) {
      return _settle(velocity: Offset.zero, forceCommit: true);
    }
    return null;
  }

  NovelTurnDecision? end({required Offset velocity}) {
    if (!_pointerActive) return null;
    if (_state.phase != NovelTurnPhase.dragging) {
      _pointerActive = false;
      if (_state.phase == NovelTurnPhase.tracking) {
        _state = const NovelTurnState.idle();
      }
      return null;
    }
    return _settle(velocity: velocity);
  }

  NovelTurnDecision _settle({
    required Offset velocity,
    bool forceCommit = false,
  }) {
    _pointerActive = false;
    final direction = _state.direction!;
    final commit = forceCommit ||
        physics.shouldCommit(
          direction: direction,
          progress: _state.progress,
          velocityX: velocity.dx,
        );
    final duration = commit
        ? physics.commitDuration(
            progress: _state.progress,
            velocity: velocity.dx,
          )
        : physics.rollbackDuration;
    _settlementCommits = commit;
    _state = NovelTurnState(
      phase: NovelTurnPhase.settling,
      direction: direction,
      progress: _state.progress,
      dragOffset: _state.dragOffset,
      touchOrigin: _state.touchOrigin,
      touchPosition: _state.touchPosition,
      viewport: _state.viewport,
    );
    return NovelTurnDecision(
      commit: commit,
      direction: direction,
      duration: duration,
    );
  }

  NovelTurnDecision startDiscrete(NovelTurnDirection direction) {
    if (_state.phase != NovelTurnPhase.idle) {
      throw StateError('Cannot start a discrete turn while busy.');
    }
    final viewport = _viewport.width > 0 && _viewport.height > 0
        ? _viewport
        : const Size(1, 1);
    final origin = _discreteOrigin ??
        Offset(
          direction == NovelTurnDirection.next ? viewport.width : 0,
          viewport.height * .82,
        );
    _discreteOrigin = null;
    _settlementCommits = true;
    _state = NovelTurnState(
      phase: NovelTurnPhase.settling,
      direction: direction,
      touchOrigin: origin,
      touchPosition: origin,
      viewport: viewport,
    );
    return NovelTurnDecision(
      commit: true,
      direction: direction,
      duration: physics.tapDuration,
    );
  }

  void setDiscreteOrigin(Offset position, Size viewport) {
    if (!viewport.width.isFinite ||
        viewport.width <= 0 ||
        !viewport.height.isFinite ||
        viewport.height <= 0) {
      return;
    }
    _viewport = viewport;
    _discreteOrigin = Offset(
      position.dx.clamp(0, viewport.width),
      position.dy.clamp(0, viewport.height),
    );
  }

  void setViewport(Size viewport) {
    if (viewport.width.isFinite &&
        viewport.width > 0 &&
        viewport.height.isFinite &&
        viewport.height > 0) {
      _viewport = viewport;
    }
  }

  bool queueDiscrete(NovelTurnDirection direction) {
    if (_state.phase == NovelTurnPhase.idle || _queuedDirection != null) {
      return false;
    }
    _queuedDirection = direction;
    return true;
  }

  NovelTurnDirection? takeQueuedDirection() {
    final value = _queuedDirection;
    _queuedDirection = null;
    return value;
  }

  NovelTurnDirection? consumeCommittedDirection() {
    final value = _committedDirection;
    _committedDirection = null;
    return value;
  }

  void completeSettlement() {
    if (_state.phase != NovelTurnPhase.settling) return;
    if (!_settlementCommits) {
      _committedDirection = null;
      _state = const NovelTurnState.idle();
      return;
    }
    _committedDirection = _state.direction;
    _state = NovelTurnState(
      phase: NovelTurnPhase.committing,
      direction: _state.direction,
      progress: 1,
      dragOffset: _state.dragOffset,
      touchOrigin: _state.touchOrigin,
      touchPosition: _state.touchPosition,
      viewport: _state.viewport,
    );
  }

  void completeCommit() {
    if (_state.phase != NovelTurnPhase.committing) return;
    _settlementCommits = false;
    _committedDirection = null;
    _state = const NovelTurnState.idle();
  }

  void cancel() {
    _pointerActive = false;
    _settlementCommits = false;
    _committedDirection = null;
    _queuedDirection = null;
    _discreteOrigin = null;
    _state = const NovelTurnState.idle();
  }
}
