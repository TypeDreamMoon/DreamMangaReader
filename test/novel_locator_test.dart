import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('semantic locator round trips all optional anchor fields', () {
    const anchor = NovelLocator(
      chapterId: 'c1',
      blockId: 'p7',
      charOffset: 12,
      quote: '目标文字',
      prefix: '前文',
      suffix: '后文',
      fraction: .4,
    );

    final json = anchor.toJson();
    final restored = NovelLocator.fromJson(json);

    expect(restored.chapterId, 'c1');
    expect(restored.blockId, 'p7');
    expect(restored.charOffset, 12);
    expect(restored.quote, '目标文字');
    expect(restored.prefix, '前文');
    expect(restored.suffix, '后文');
    expect(restored.fraction, .4);
  });

  test('legacy locator JSON remains valid and fraction stays clamped', () {
    final locator = NovelLocator.fromJson(const {
      'chapterId': 'legacy',
      'blockId': 'p2',
      'fraction': 4,
    });

    expect(locator.chapterId, 'legacy');
    expect(locator.blockId, 'p2');
    expect(locator.fraction, 1);
    expect(locator.charOffset, isNull);
    expect(locator.quote, isNull);
    expect(locator.prefix, isNull);
    expect(locator.suffix, isNull);
  });

  test('reading progress history retains semantic locator fields', () {
    const progress = NovelReadingProgress(
      locator: NovelLocator(
        chapterId: 'c2',
        blockId: 'p9',
        charOffset: 31,
        quote: 'quote',
        prefix: 'before',
        suffix: 'after',
        fraction: .75,
      ),
      updatedAt: 1234,
    );

    final restored = NovelReadingProgress.fromJson(progress.toJson());

    expect(restored.locator.charOffset, 31);
    expect(restored.locator.quote, 'quote');
    expect(restored.locator.prefix, 'before');
    expect(restored.locator.suffix, 'after');
    expect(restored.updatedAt, 1234);
  });
}
