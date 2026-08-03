import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/detail/chapter_order.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('published chapters ignore unrelated numbers in their titles', () {
    const chapter = Chapter(
      id: 'p1',
      name: '写真 No.11017 (75 photos)',
      publishedAt: 200,
    );

    final order = chapterOrder(chapter, 0);

    expect(order.number, isNull);
    expect(order.publishedAt, 200);
  });

  test('date chapters sort oldest to newest before display reversal', () {
    final older = chapterOrder(
      const Chapter(id: 'old', name: '旧帖', publishedAt: 100),
      0,
    );
    final newer = chapterOrder(
      const Chapter(id: 'new', name: '新帖', publishedAt: 200),
      1,
    );

    expect(compareChapterOrder(older, newer), lessThan(0));
  });

  test('new installs default to newest first and saved choices win', () async {
    SharedPreferences.setMockInitialValues({});
    final fresh = LibraryStore();
    await fresh.load();
    expect(fresh.chaptersDesc, true);
    fresh.dispose();

    SharedPreferences.setMockInitialValues({'lib.chaptersDesc': false});
    final restored = LibraryStore();
    await restored.load();
    expect(restored.chaptersDesc, false);
    restored.dispose();
  });
}
