import 'dart:math' as math;

enum NovelTurnDirection { previous, next }

class NovelPageTurnPhysics {
  const NovelPageTurnPhysics({
    this.touchSlop = 10,
    this.axisDominanceRatio = 1.15,
    this.distanceThreshold = .28,
    this.flingVelocity = 700,
    this.minCommitDuration = const Duration(milliseconds: 140),
    this.maxCommitDuration = const Duration(milliseconds: 280),
    this.rollbackDuration = const Duration(milliseconds: 180),
    this.tapDuration = const Duration(milliseconds: 260),
    this.maximumFoldAngle = 60,
    this.angleCommitProgress = .08,
  });

  final double touchSlop;
  final double axisDominanceRatio;
  final double distanceThreshold;
  final double flingVelocity;
  final Duration minCommitDuration;
  final Duration maxCommitDuration;
  final Duration rollbackDuration;
  final Duration tapDuration;
  final double maximumFoldAngle;
  final double angleCommitProgress;

  bool shouldLockHorizontal({required double dx, required double dy}) {
    return dx.abs() >= touchSlop && dx.abs() > dy.abs() * axisDominanceRatio;
  }

  bool shouldRejectAsVertical({required double dx, required double dy}) {
    return dy.abs() >= touchSlop && dy.abs() >= dx.abs() * axisDominanceRatio;
  }

  bool shouldCommit({
    required NovelTurnDirection direction,
    required double progress,
    required double velocityX,
  }) {
    if (progress >= distanceThreshold) return true;
    final alignedVelocity = switch (direction) {
      NovelTurnDirection.next => -velocityX,
      NovelTurnDirection.previous => velocityX,
    };
    return alignedVelocity >= flingVelocity;
  }

  bool reachesFoldAngleLimit({
    required double progress,
    required double dx,
    required double dy,
    required double viewportWidth,
    required double viewportHeight,
  }) {
    if (progress < angleCommitProgress ||
        viewportWidth <= 0 ||
        viewportHeight <= 0) {
      return false;
    }
    final horizontal = dx.abs().clamp(0.0, viewportWidth);
    final vertical = dy.clamp(-viewportHeight, viewportHeight);
    final horizontalFactor =
        1 - .9 * (horizontal / viewportWidth).clamp(0.0, 1.0);
    final verticalFactor =
        1 - .995 * (vertical.abs() / viewportHeight).clamp(0.0, 1.0);
    final foldAngle = vertical.abs() * horizontalFactor * verticalFactor;
    return foldAngle >= maximumFoldAngle;
  }

  Duration commitDuration({
    required double progress,
    required double velocity,
  }) {
    final clampedProgress = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    final remaining = 1 - clampedProgress;
    final minMs = minCommitDuration.inMilliseconds;
    final rangeMs = maxCommitDuration.inMilliseconds - minMs;
    final velocityReduction = math.min(velocity.abs() / 2400, .35);
    final scaled = minMs + rangeMs * remaining * (1 - velocityReduction);
    return Duration(
      milliseconds:
          scaled.round().clamp(minMs, maxCommitDuration.inMilliseconds),
    );
  }
}
