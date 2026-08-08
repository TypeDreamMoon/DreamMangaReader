import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/novel/reader/novel_page_turn_controller.dart';
import '../../core/novel/reader/novel_page_turn_physics.dart';

class NovelReaderInput extends StatefulWidget {
  const NovelReaderInput({
    super.key,
    required this.controller,
    required this.blocked,
    required this.singleHandNext,
    required this.onStateChanged,
    required this.onDecision,
    required this.onDiscrete,
    required this.onToggleControls,
    required this.child,
    this.dragEnabled = true,
  });

  final NovelPageTurnController controller;
  final bool blocked;
  final bool singleHandNext;
  final bool dragEnabled;
  final VoidCallback onStateChanged;
  final ValueChanged<NovelTurnDecision> onDecision;
  final ValueChanged<NovelTurnDirection> onDiscrete;
  final VoidCallback onToggleControls;
  final Widget child;

  @override
  State<NovelReaderInput> createState() => _NovelReaderInputState();
}

class _NovelReaderInputState extends State<NovelReaderInput> {
  int? _activePointer;
  Offset _lastPosition = Offset.zero;
  Duration _startedAt = Duration.zero;
  Duration _lastMoveAt = Duration.zero;
  double _velocityX = 0;
  Duration? _lastWheelAt;

  @override
  void didUpdateWidget(covariant NovelReaderInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.blocked && widget.blocked) {
      _cancelPointer(notify: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onStateChanged();
      });
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.blocked || !widget.dragEnabled || _activePointer != null) return;
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(event.position);
    _activePointer = event.pointer;
    _lastPosition = local;
    _startedAt = event.timeStamp;
    _lastMoveAt = event.timeStamp;
    _velocityX = 0;
    widget.controller.begin(local, box.size);
    widget.onStateChanged();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (widget.blocked || event.pointer != _activePointer) return;
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(event.position);
    final elapsed = event.timeStamp - _lastMoveAt;
    if (elapsed.inMicroseconds > 0) {
      _velocityX = (local.dx - _lastPosition.dx) /
          elapsed.inMicroseconds *
          Duration.microsecondsPerSecond;
    }
    _lastPosition = local;
    _lastMoveAt = event.timeStamp;
    final decision = widget.controller.update(
      local,
      elapsed: event.timeStamp - _startedAt,
    );
    widget.onStateChanged();
    if (decision != null) {
      _activePointer = null;
      widget.onDecision(decision);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    if (widget.blocked) {
      widget.controller.cancel();
      widget.onStateChanged();
      return;
    }
    final decision = widget.controller.end(
      velocity: Offset(_velocityX, 0),
    );
    widget.onStateChanged();
    if (decision != null) widget.onDecision(decision);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _activePointer) _cancelPointer();
  }

  void _cancelPointer({bool notify = true}) {
    _activePointer = null;
    widget.controller.cancel();
    if (notify) widget.onStateChanged();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (widget.blocked || event is! PointerScrollEvent) return;
    if (event.scrollDelta.distance < 12) return;
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final previous = _lastWheelAt;
    if (previous != null &&
        now - previous < const Duration(milliseconds: 250)) {
      return;
    }
    _lastWheelAt = now;
    final primary = event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    widget.onDiscrete(
      primary > 0 ? NovelTurnDirection.next : NovelTurnDirection.previous,
    );
  }

  void _onTapUp(TapUpDetails details) {
    if (widget.blocked) return;
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final ratio = (details.localPosition.dx / width).clamp(0.0, 1.0);
    if (ratio >= .25 && ratio <= .75) {
      widget.onToggleControls();
      return;
    }
    final size = context.size;
    if (size != null) {
      widget.controller.setDiscreteOrigin(details.localPosition, size);
    }
    if (widget.singleHandNext) {
      widget.onDiscrete(NovelTurnDirection.next);
      return;
    }
    widget.onDiscrete(
      ratio < .25 ? NovelTurnDirection.previous : NovelTurnDirection.next,
    );
  }

  void _discrete(NovelTurnDirection direction) {
    if (!widget.blocked) widget.onDiscrete(direction);
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft):
            _NovelTurnIntent(NovelTurnDirection.previous),
        SingleActivator(LogicalKeyboardKey.pageUp):
            _NovelTurnIntent(NovelTurnDirection.previous),
        SingleActivator(LogicalKeyboardKey.arrowRight):
            _NovelTurnIntent(NovelTurnDirection.next),
        SingleActivator(LogicalKeyboardKey.pageDown):
            _NovelTurnIntent(NovelTurnDirection.next),
        SingleActivator(LogicalKeyboardKey.space):
            _NovelTurnIntent(NovelTurnDirection.next),
        SingleActivator(LogicalKeyboardKey.enter): _NovelToggleIntent(),
      },
      child: Actions(
        actions: {
          _NovelTurnIntent: CallbackAction<_NovelTurnIntent>(
            onInvoke: (intent) {
              _discrete(intent.direction);
              return null;
            },
          ),
          _NovelToggleIntent: CallbackAction<_NovelToggleIntent>(
            onInvoke: (_) {
              if (!widget.blocked) widget.onToggleControls();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            onPointerSignal: _onPointerSignal,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: _onTapUp,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class _NovelTurnIntent extends Intent {
  const _NovelTurnIntent(this.direction);

  final NovelTurnDirection direction;
}

class _NovelToggleIntent extends Intent {
  const _NovelToggleIntent();
}
