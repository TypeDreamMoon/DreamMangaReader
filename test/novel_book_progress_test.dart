import 'package:dream_manga_reader/features/novel/novel_book_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('book progress combines chapter index and chapter fraction', () {
    expect(
      novelBookProgress(
        chapterIndex: 1,
        chapterFraction: .5,
        chapterCount: 4,
      ),
      closeTo(.375, .0001),
    );
  });

  test('slider target maps one to the final chapter end', () {
    expect(
      novelProgressTarget(progress: 1, chapterCount: 4),
      const NovelProgressTarget(chapterIndex: 3, chapterFraction: 1),
    );
  });

  test('progress helpers clamp invalid inputs', () {
    expect(
      novelBookProgress(
        chapterIndex: -2,
        chapterFraction: -1,
        chapterCount: 0,
      ),
      0,
    );
    expect(
      novelProgressTarget(progress: 2, chapterCount: 2),
      const NovelProgressTarget(chapterIndex: 1, chapterFraction: 1),
    );
    expect(
      novelProgressTarget(progress: double.nan, chapterCount: 2),
      const NovelProgressTarget(chapterIndex: 0, chapterFraction: 0),
    );
  });
}
