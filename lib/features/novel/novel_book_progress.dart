class NovelProgressTarget {
  const NovelProgressTarget({
    required this.chapterIndex,
    required this.chapterFraction,
  });

  final int chapterIndex;
  final double chapterFraction;

  @override
  bool operator ==(Object other) =>
      other is NovelProgressTarget &&
      other.chapterIndex == chapterIndex &&
      other.chapterFraction == chapterFraction;

  @override
  int get hashCode => Object.hash(chapterIndex, chapterFraction);
}

double novelBookProgress({
  required int chapterIndex,
  required double chapterFraction,
  required int chapterCount,
}) {
  if (chapterCount <= 0) return 0;
  final index = chapterIndex.clamp(0, chapterCount - 1).toInt();
  final fraction = (chapterFraction.isFinite ? chapterFraction : 0.0)
      .clamp(0.0, 1.0)
      .toDouble();
  return ((index + fraction) / chapterCount).clamp(0.0, 1.0).toDouble();
}

NovelProgressTarget novelProgressTarget({
  required double progress,
  required int chapterCount,
}) {
  if (chapterCount <= 0) {
    return const NovelProgressTarget(chapterIndex: 0, chapterFraction: 0);
  }
  final value = (progress.isFinite ? progress : 0.0).clamp(0.0, 1.0).toDouble();
  if (value >= 1) {
    return NovelProgressTarget(
      chapterIndex: chapterCount - 1,
      chapterFraction: 1,
    );
  }
  final scaled = value * chapterCount;
  final index = scaled.floor().clamp(0, chapterCount - 1).toInt();
  return NovelProgressTarget(
    chapterIndex: index,
    chapterFraction: (scaled - index).clamp(0.0, 1.0).toDouble(),
  );
}
