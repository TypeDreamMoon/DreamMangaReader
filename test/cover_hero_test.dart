import 'package:dream_manga_reader/features/common/cover_hero.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('同屏并存的区域给出不同 tag —— 书架收藏区与历史横条会同时出现同一部书', () {
    const sourceId = 'copymanga';
    const itemId = 'one-piece';
    final shelf = coverHeroTag(CoverHeroScope.shelf,
        sourceId: sourceId, itemId: itemId);
    final history = coverHeroTag(CoverHeroScope.shelfHistory,
        sourceId: sourceId, itemId: itemId);
    // 同 tag 同屏 = Flutter 直接抛异常,这条是整套前缀机制存在的理由。
    expect(shelf, isNot(history));
  });

  test('每个区域的前缀互不相同', () {
    final prefixes = CoverHeroScope.values.map((s) => s.prefix).toList();
    expect(prefixes.toSet(), hasLength(prefixes.length));
  });

  test('同源同作品得到稳定的 tag —— 列表侧与详情侧必须算出同一个值', () {
    final a = coverHeroTag(CoverHeroScope.discovery,
        sourceId: 'src', itemId: 'work');
    final b = coverHeroTag(CoverHeroScope.discovery,
        sourceId: 'src', itemId: 'work');
    expect(a, b);
  });

  test('带下标区分同一列表里重复召回的同一部作品', () {
    final first = coverHeroTag(CoverHeroScope.discovery,
        sourceId: 'src', itemId: 'work', index: 0);
    final second = coverHeroTag(CoverHeroScope.discovery,
        sourceId: 'src', itemId: 'work', index: 7);
    expect(first, isNot(second));
    // 不传下标时不留尾巴(横条/网格里每部书只出现一次)。
    expect(
      coverHeroTag(CoverHeroScope.discovery, sourceId: 'src', itemId: 'work'),
      'disc:src:work',
    );
  });

  test('不同源的同名作品不撞 —— 混合源结果里同一本书来自多个源', () {
    final a =
        coverHeroTag(CoverHeroScope.discovery, sourceId: 'a', itemId: 'work');
    final b =
        coverHeroTag(CoverHeroScope.discovery, sourceId: 'b', itemId: 'work');
    expect(a, isNot(b));
  });
}
