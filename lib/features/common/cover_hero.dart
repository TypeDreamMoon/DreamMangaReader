/// 封面 →(详情页)大封面的 Hero 飞入动画,tag 一律从这里生成。
///
/// 为什么要收成一处:
///
/// 1. **Hero 要求同屏 tag 唯一**。书架上同一部书可能同时出现在「历史」横条和「收藏」
///    网格里,两处若用同一个 tag,Flutter 直接抛「同屏多个相同 tag」。所以 tag 一律
///    带**区域前缀**([CoverHeroScope]),按区域天然隔开。
/// 2. **列表侧和详情侧必须传同一个值**。两个调用点各拼各的字符串,就会出现「有的页面
///    有飞入动画、有的没有」——本来就是各页自己拼、格式还都不一样。
///
/// 用法:列表侧 `MangaCover(heroTag: coverHeroTag(...))`,导航时把同一个值传给详情页。
library;

/// 封面出现的区域。同屏可能并存的区域必须是**不同**的值,否则 Hero 撞 tag。
enum CoverHeroScope {
  /// 发现页的结果网格 / 列表。
  discovery('disc'),

  /// 站点板块浏览(排行榜/连载/完结…)。
  browseSection('browse'),

  /// 发现页顶部的「为你推荐」。
  recommend('rec'),

  /// 「同作者作品」页。
  authorWorks('author'),

  /// 书架的收藏区。瀑布流/网格/列表三种布局同一时刻只渲染一种,共用一个前缀即可。
  shelf('shelf'),

  /// 书架顶部的「历史记录」横条。它和收藏区**同屏**,所以必须是独立前缀 ——
  /// 同一部书同时出现在两处是常态。
  shelfHistory('shelfhist'),

  /// 独立的「阅读历史」页。
  history('hist'),

  /// 下载页。
  downloads('dl');

  const CoverHeroScope(this.prefix);

  final String prefix;
}

/// 生成封面 Hero 的 tag。
///
/// [itemId] 是作品 id(漫画/番剧的 mangaId、小说的 novelId 或指纹)。
/// [index] 给「同一部作品可能在一个列表里出现多次」的场景(混合源翻页会重复召回),
/// 不传则省略 —— 横条/网格里每部书只出现一次时更稳定。
String coverHeroTag(
  CoverHeroScope scope, {
  required String sourceId,
  required String itemId,
  int? index,
}) {
  final base = '${scope.prefix}:$sourceId:$itemId';
  return index == null ? base : '$base:$index';
}
