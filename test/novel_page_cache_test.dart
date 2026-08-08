import 'dart:typed_data';

import 'package:dream_manga_reader/core/novel/reader/novel_page_cache.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NovelPageCache', () {
    test('retains previous current and next frames inside the budget', () {
      final cache = NovelPageCache(byteBudget: 9);
      final previous = _frame(pageIndex: 0, byteSize: 3);
      final current = _frame(pageIndex: 1, byteSize: 3);
      final next = _frame(pageIndex: 2, byteSize: 3);

      cache.put(previous);
      cache.put(current);
      cache.put(next);
      cache.pinCurrent(current.key);

      expect(cache.length, 3);
      expect(cache.totalBytes, 9);
      expect(cache.get(previous.key), same(previous));
      expect(cache.get(current.key), same(current));
      expect(cache.get(next.key), same(next));
    });

    test('get promotes a frame before least recently used eviction', () {
      final cache = NovelPageCache(byteBudget: 9);
      final first = _frame(pageIndex: 0, byteSize: 3);
      final second = _frame(pageIndex: 1, byteSize: 3);
      final third = _frame(pageIndex: 2, byteSize: 3);
      final fourth = _frame(pageIndex: 3, byteSize: 3);

      cache.put(first);
      cache.put(second);
      cache.put(third);
      expect(cache.get(first.key), same(first));

      cache.put(fourth);

      expect(cache.get(second.key), isNull);
      expect(cache.get(first.key), same(first));
      expect(cache.get(third.key), same(third));
      expect(cache.get(fourth.key), same(fourth));
    });

    test('never evicts the pinned current frame to satisfy the budget', () {
      final cache = NovelPageCache(byteBudget: 6);
      final current = _frame(pageIndex: 0, byteSize: 4);
      final other = _frame(pageIndex: 1, byteSize: 4);

      cache.put(current);
      cache.pinCurrent(current.key);
      cache.put(other);

      expect(cache.get(current.key), same(current));
      expect(cache.get(other.key), isNull);
      expect(cache.totalBytes, 4);
    });

    test('keeps an oversized pinned current frame as the sole entry', () {
      final cache = NovelPageCache(byteBudget: 3);
      final current = _frame(pageIndex: 0, byteSize: 5);
      final other = _frame(pageIndex: 1, byteSize: 1);

      cache.put(current);
      cache.pinCurrent(current.key);
      cache.put(other);

      expect(cache.get(current.key), same(current));
      expect(cache.get(other.key), isNull);
      expect(cache.totalBytes, 5);
    });

    test('invalidates every frame from a stale layout fingerprint', () {
      final cache = NovelPageCache(byteBudget: 12);
      final stale = _frame(pageIndex: 0, byteSize: 3, layout: 'old');
      final current = _frame(pageIndex: 1, byteSize: 3, layout: 'new');
      final next = _frame(pageIndex: 2, byteSize: 3, layout: 'new');

      cache.put(stale);
      cache.put(current);
      cache.put(next);
      cache.pinCurrent(current.key);
      cache.invalidateLayout('new');

      expect(cache.get(stale.key), isNull);
      expect(cache.get(current.key), same(current));
      expect(cache.get(next.key), same(next));
      expect(cache.totalBytes, 6);
    });

    test('layout invalidation keeps the pinned visible frame until replaced',
        () {
      final cache = NovelPageCache(byteBudget: 9);
      final current = _frame(pageIndex: 0, byteSize: 3, layout: 'old');
      final stale = _frame(pageIndex: 1, byteSize: 3, layout: 'old');

      cache.put(current);
      cache.put(stale);
      cache.pinCurrent(current.key);
      cache.invalidateLayout('new');

      expect(cache.get(current.key), same(current));
      expect(cache.get(stale.key), isNull);
    });

    test('memory pressure shrinks to the pinned current frame', () {
      final cache = NovelPageCache(byteBudget: 12);
      final previous = _frame(pageIndex: 0, byteSize: 3);
      final current = _frame(pageIndex: 1, byteSize: 3);
      final next = _frame(pageIndex: 2, byteSize: 3);

      cache.put(previous);
      cache.put(current);
      cache.put(next);
      cache.pinCurrent(current.key);
      cache.shrinkForMemoryPressure();

      expect(cache.length, 1);
      expect(cache.get(current.key), same(current));
      expect(cache.totalBytes, 3);
    });

    test('page frame stores a defensive compact byte view', () {
      final source = <int>[1, 2, 3];
      final frame = NovelPageFrame(
        key: _key(0),
        viewport: const NovelViewport(width: 1000, height: 1600),
        bytes: source,
      );
      source[0] = 9;

      expect(frame.bytes, isA<Uint8List>());
      expect(frame.bytes, [1, 2, 3]);
      expect(() => frame.bytes[0] = 9, throwsUnsupportedError);
    });
  });
}

NovelPageFrame _frame({
  required int pageIndex,
  required int byteSize,
  String layout = 'layout',
}) {
  return NovelPageFrame(
    key: _key(pageIndex, layout: layout),
    viewport: const NovelViewport(width: 1000, height: 1600),
    bytes: List<int>.filled(byteSize, pageIndex),
  );
}

NovelPageKey _key(int pageIndex, {String layout = 'layout'}) {
  return NovelPageKey(
    chapterId: 'chapter-1',
    pageIndex: pageIndex,
    layoutFingerprint: layout,
  );
}
