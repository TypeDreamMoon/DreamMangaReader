import '../../core/source/chapter_number.dart';
import '../../core/source/models.dart';

class ChapterOrder {
  const ChapterOrder({this.number, this.publishedAt, required this.index});

  final double? number;
  final int? publishedAt;
  final int index;
}

ChapterOrder chapterOrder(Chapter chapter, int index) {
  if (chapter.number != null) {
    return ChapterOrder(number: chapter.number, index: index);
  }
  if (chapter.publishedAt != null) {
    return ChapterOrder(publishedAt: chapter.publishedAt, index: index);
  }
  return ChapterOrder(number: parseChapterNumber(chapter.name), index: index);
}

int compareChapterOrder(ChapterOrder left, ChapterOrder right) {
  if (left.number != null || right.number != null) {
    final value = (left.number ?? double.infinity)
        .compareTo(right.number ?? double.infinity);
    if (value != 0) return value;
  } else if (left.publishedAt != null || right.publishedAt != null) {
    final value = (left.publishedAt ?? 0).compareTo(right.publishedAt ?? 0);
    if (value != 0) return value;
  }
  return left.index.compareTo(right.index);
}
