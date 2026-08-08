import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:page_curl_effect/page_curl_effect.dart' as page_curl;
// The package does not publicly export its clipper/painter geometry.
// ignore: implementation_imports
import 'package:page_curl_effect/src/widget/page_curl_clipper.dart'
    as page_curl;
// ignore: implementation_imports
import 'package:page_curl_effect/src/widget/page_curl_painter.dart'
    as page_curl;

import '../../core/novel/reader/novel_page_turn_controller.dart';
import '../../core/novel/reader/novel_page_turn_physics.dart';
import '../../core/novel/reader/novel_paginator.dart';
import 'novel_native_page_view.dart';

class NovelNativePageTurnSurface extends StatefulWidget {
  const NovelNativePageTurnSurface({
    super.key,
    required this.pagination,
    required this.currentSpreadIndex,
    required this.state,
    this.settlement,
    required this.canvasColor,
    required this.pageColor,
    required this.textColor,
    required this.onCommitted,
    this.previousPageImage,
    this.currentPageImage,
    this.nextPageImage,
    this.onSettled,
  });

  final NovelPaginationResult pagination;
  final int currentSpreadIndex;
  final NovelTurnState state;
  final NovelTurnDecision? settlement;
  final Color canvasColor;
  final Color pageColor;
  final Color textColor;
  final ui.Image? previousPageImage;
  final ui.Image? currentPageImage;
  final ui.Image? nextPageImage;
  final ValueChanged<NovelTurnDirection> onCommitted;
  final VoidCallback? onSettled;

  @override
  State<NovelNativePageTurnSurface> createState() =>
      _NovelNativePageTurnSurfaceState();
}

class _NovelNativePageTurnSurfaceState extends State<NovelNativePageTurnSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  NovelTurnDecision? _handledSettlement;
  NovelTurnDecision? _activeSettlement;
  Offset _settlementStartTouch = Offset.zero;
  Offset _settlementTargetTouch = Offset.zero;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(vsync: this)
      ..addListener(() => setState(() {}))
      ..addStatusListener(_onAnimationStatus);
    _startSettlement();
  }

  @override
  void didUpdateWidget(covariant NovelNativePageTurnSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.settlement, oldWidget.settlement) ||
        widget.state.phase != oldWidget.state.phase) {
      _startSettlement();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  void _startSettlement() {
    if (!mounted || widget.state.phase != NovelTurnPhase.settling) return;
    final settlement = widget.settlement;
    if (settlement == null || identical(settlement, _handledSettlement)) return;
    if (settlement.commit && !_hasTarget(settlement.direction)) return;
    _handledSettlement = settlement;
    _activeSettlement = settlement;
    final leaf = _turningLeaf(settlement.direction);
    _settlementStartTouch = widget.state.touchPosition == Offset.zero
        ? widget.state.touchOrigin
        : widget.state.touchPosition;
    _settlementTargetTouch = settlement.commit
        ? _completionTarget(leaf, settlement.direction)
        : widget.state.touchOrigin;
    _animation
      ..stop()
      ..duration = settlement.duration
      ..value = 0;
    _animation.forward();
  }

  void _onAnimationStatus(AnimationStatus status) {
    final settlement = _activeSettlement;
    if (settlement == null) return;
    final finished = status == AnimationStatus.completed;
    if (!finished) return;
    _activeSettlement = null;
    if (settlement.commit) widget.onCommitted(settlement.direction);
    widget.onSettled?.call();
  }

  bool _hasTarget(NovelTurnDirection direction) {
    final target = widget.currentSpreadIndex +
        (direction == NovelTurnDirection.next ? 1 : -1);
    return target >= 0 && target < widget.pagination.spreads.length;
  }

  @override
  Widget build(BuildContext context) {
    final direction = widget.state.direction ?? NovelTurnDirection.next;
    final targetIndex = widget.currentSpreadIndex +
        (direction == NovelTurnDirection.next ? 1 : -1);
    final hasTarget = _hasTarget(direction);
    final targetImage = direction == NovelTurnDirection.next
        ? widget.nextPageImage
        : widget.previousPageImage;
    final progress = hasTarget ? _progress : 0.0;
    final turningLeaf = _turningLeaf(direction);
    final touch = _touchPoint(turningLeaf, direction);
    final curl = _NovelCurlLayer.resolve(
      leaf: turningLeaf,
      touchOrigin: widget.state.touchOrigin,
      touchPosition: touch,
      direction: direction,
      progress: progress,
    );

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasTarget)
            KeyedSubtree(
              key: const Key('novel-native-turn-target'),
              child: targetImage == null
                  ? NovelNativePageView(
                      pagination: widget.pagination,
                      spreadIndex: targetIndex,
                      canvasColor: widget.canvasColor,
                      pageColor: widget.pageColor,
                      textColor: widget.textColor,
                    )
                  : _cachedSpread(
                      key: const Key('novel-native-cached-target'),
                      image: targetImage,
                    ),
            ),
          ClipPath(
            key: const Key('novel-native-current-curl-clip'),
            clipper: _NovelCurrentSpreadClipper(
              turningLeaf: turningLeaf,
              visibleLeafPath: curl.visibleLeafPath,
            ),
            child: KeyedSubtree(
              key: const Key('novel-native-turn-current'),
              child: widget.currentPageImage == null
                  ? NovelNativePageView(
                      pagination: widget.pagination,
                      spreadIndex: widget.currentSpreadIndex,
                      canvasColor: widget.canvasColor,
                      pageColor: widget.pageColor,
                      textColor: widget.textColor,
                    )
                  : _cachedSpread(
                      key: const Key('novel-native-cached-current'),
                      image: widget.currentPageImage!,
                    ),
            ),
          ),
          if (progress > 0 && curl.sheetPainter != null)
            Positioned.fromRect(
              rect: turningLeaf,
              child: IgnorePointer(
                child: Transform(
                  key: curl.mirrored
                      ? const Key('novel-native-curl-mirrored')
                      : null,
                  alignment: Alignment.center,
                  transform: curl.mirrored
                      ? (Matrix4.identity()..scaleByDouble(-1, 1, 1, 1))
                      : Matrix4.identity(),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          widget.pageColor,
                          BlendMode.modulate,
                        ),
                        child: CustomPaint(
                          key: const Key('novel-native-curl-sheet'),
                          painter: curl.sheetPainter,
                        ),
                      ),
                      const SizedBox.expand(
                        key: Key('novel-native-page-back'),
                      ),
                      const SizedBox.expand(
                        key: Key('novel-native-fold-shadow'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  double get _progress {
    final settlement = _activeSettlement;
    if (widget.state.phase == NovelTurnPhase.settling && settlement != null) {
      final t = Curves.easeOutCubic.transform(_animation.value);
      final value = ui
          .lerpDouble(
            widget.state.progress.clamp(0.0, 1.0),
            settlement.commit ? 1 : 0,
            t,
          )!
          .clamp(0.0, 1.0);
      return settlement.commit && value == 0 ? .001 : value;
    }
    return widget.state.progress.clamp(0.0, 1.0);
  }

  Rect _turningLeaf(NovelTurnDirection direction) {
    final leaves = widget.pagination.leafRects;
    if (leaves.length == 1) return leaves.single;
    return direction == NovelTurnDirection.next ? leaves[1] : leaves[0];
  }

  Offset _touchPoint(
    Rect leaf,
    NovelTurnDirection direction,
  ) {
    final live = widget.state.touchPosition;
    final origin = widget.state.touchOrigin == Offset.zero
        ? Offset(
            direction == NovelTurnDirection.next ? leaf.right : leaf.left,
            leaf.bottom - leaf.height * .18,
          )
        : widget.state.touchOrigin;
    Offset constrained(Offset value) => _limitFoldAngle(
          origin: origin,
          touch: _boundedTouch(value, leaf),
          leaf: leaf,
        );
    if (widget.state.phase == NovelTurnPhase.dragging) {
      return constrained(live);
    }
    if (widget.state.phase == NovelTurnPhase.settling) {
      if (_activeSettlement == null) {
        return constrained(live == Offset.zero ? origin : live);
      }
      final t = Curves.easeOutCubic.transform(_animation.value);
      return constrained(
        Offset(
          ui.lerpDouble(
            _settlementStartTouch.dx,
            _settlementTargetTouch.dx,
            t,
          )!,
          ui.lerpDouble(
            _settlementStartTouch.dy,
            _settlementTargetTouch.dy,
            t,
          )!,
        ),
      );
    }
    if (widget.state.phase == NovelTurnPhase.committing) {
      return constrained(_completionTarget(leaf, direction));
    }
    return constrained(live == Offset.zero ? origin : live);
  }

  Offset _completionTarget(Rect leaf, NovelTurnDirection direction) {
    return Offset(
      direction == NovelTurnDirection.next
          ? leaf.left - leaf.width * .14
          : leaf.right + leaf.width * .14,
      leaf.center.dy,
    );
  }

  Offset _boundedTouch(Offset value, Rect leaf) {
    return Offset(
      value.dx
          .clamp(leaf.left - leaf.width * .18, leaf.right + leaf.width * .18),
      value.dy.clamp(leaf.top + 1, leaf.bottom - 1),
    );
  }

  Widget _cachedSpread({required Key key, required ui.Image image}) {
    return RepaintBoundary(
      child: RawImage(
        key: key,
        image: image,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.low,
      ),
    );
  }

  Offset _limitFoldAngle({
    required Offset origin,
    required Offset touch,
    required Rect leaf,
  }) {
    const safeAngle = 56.0;
    final horizontal = (touch.dx - origin.dx).abs().clamp(0.0, leaf.width);
    final vertical = touch.dy - origin.dy;
    final verticalAbs = vertical.abs().clamp(0.0, leaf.height * .48);
    final horizontalFactor = 1 - .9 * (horizontal / leaf.width).clamp(0.0, 1.0);

    double angleAt(double distance) {
      final verticalFactor =
          1 - .995 * (distance / leaf.height).clamp(0.0, 1.0);
      return distance * horizontalFactor * verticalFactor;
    }

    if (angleAt(verticalAbs) <= safeAngle) return touch;
    var low = 0.0;
    var high = verticalAbs;
    for (var i = 0; i < 18; i++) {
      final middle = (low + high) / 2;
      if (angleAt(middle) <= safeAngle) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return Offset(touch.dx, origin.dy + (vertical.isNegative ? -low : low));
  }
}

class _NovelCurlLayer {
  const _NovelCurlLayer({
    required this.visibleLeafPath,
    required this.sheetPainter,
    required this.mirrored,
  });

  final Path visibleLeafPath;
  final CustomPainter? sheetPainter;
  final bool mirrored;

  factory _NovelCurlLayer.resolve({
    required Rect leaf,
    required Offset touchOrigin,
    required Offset touchPosition,
    required NovelTurnDirection direction,
    required double progress,
  }) {
    final mirrored = direction == NovelTurnDirection.previous;
    if (progress <= 0) {
      return _NovelCurlLayer(
        visibleLeafPath: Path()..addRect(Offset.zero & leaf.size),
        sheetPainter: null,
        mirrored: mirrored,
      );
    }

    Offset local(Offset value) {
      var x = (value.dx - leaf.left).clamp(0.0, leaf.width);
      final y = (value.dy - leaf.top).clamp(0.0, leaf.height);
      if (mirrored) x = leaf.width - x;
      return Offset(x, y);
    }

    final origin = local(touchOrigin);
    final touch = local(touchPosition);
    final controller = page_curl.PageCurlController(
      leaf.size,
      pageCurlIndex: 0,
      numberOfPage: 2,
    );
    controller.onAutoPanUpdate(origin);
    controller.onAutoPanUpdate(touch);

    final clipper = page_curl.PageCurlClipper(
      nullableCylinder: controller.cylinder,
      nullableHorizontalPageCurve: controller.horizontalPageCurve,
      nullableMiddlePageCurve: controller.middlePageCurve,
    );
    var path = clipper.getClip(leaf.size);
    if (mirrored) {
      final mirror = Matrix4.identity()
        ..translateByDouble(leaf.width, 0, 0, 1)
        ..scaleByDouble(-1, 1, 1, 1);
      path = path.transform(mirror.storage);
    }
    return _NovelCurlLayer(
      visibleLeafPath: path,
      sheetPainter: page_curl.PageCurlPainter(
        nullableCylinder: controller.cylinder,
        nullableHorizontalPageCurve: controller.horizontalPageCurve,
        nullableMiddlePageCurve: controller.middlePageCurve,
      ),
      mirrored: mirrored,
    );
  }
}

class _NovelCurrentSpreadClipper extends CustomClipper<Path> {
  const _NovelCurrentSpreadClipper({
    required this.turningLeaf,
    required this.visibleLeafPath,
  });

  final Rect turningLeaf;
  final Path visibleLeafPath;

  @override
  Path getClip(Size size) {
    final full = Path()..addRect(Offset.zero & size);
    final leaf = Path()..addRect(turningLeaf);
    final outsideLeaf = Path.combine(PathOperation.difference, full, leaf);
    return Path.combine(
      PathOperation.union,
      outsideLeaf,
      visibleLeafPath.shift(turningLeaf.topLeft),
    );
  }

  @override
  bool shouldReclip(covariant _NovelCurrentSpreadClipper oldClipper) {
    return oldClipper.turningLeaf != turningLeaf ||
        oldClipper.visibleLeafPath != visibleLeafPath;
  }
}
