import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../app/library_store.dart' show FeedLayout;

/// 从 seed(用 manga.id)派生一个**稳定**的封面纵横比,做出瀑布流的高低错落。
/// 同一个 id 永远得到同一个比例 —— 翻页追加 / 重建 / 滚动都不会跳动。
/// 封面源图是 3/4,这里给卡片一个 [min,max] 的比例,图仍 BoxFit.cover 填满,
/// 只是裁切多一点/少一点,于是各卡高度不同。
double aspectForId(String seed, {double min = 0.60, double max = 0.82}) {
  var h = 0;
  for (var i = 0; i < seed.length; i++) {
    h = (h * 31 + seed.codeUnitAt(i)) & 0x7fffffff;
  }
  const steps = 6; // 6 档离散比例:够错落又不至于太碎
  final t = (h % steps) / (steps - 1); // 0..1
  return min + (max - min) * t;
}

/// 按窗宽推导列数(对齐原 maxCrossAxisExtent:168 的观感)。
/// [columns] > 0 用固定列数(设置里可选),否则自适应(至少 2 列)。
int columnsFor(double width, int columns) {
  if (columns > 0) return columns;
  final n = (width / 172).floor();
  return n < 2 ? 2 : n;
}

/// 可切布局的封面信息流:瀑布流 / 网格 / 列表。
/// - [cardBuilder]:封面+标题卡(瀑布流 / 网格用);[tileBuilder]:横排行(列表用)。
/// - [controller]/[footer] 给独立滚动的场景(发现页无限滚动);[shrinkWrap]=true 供
///   嵌进外层 ListView(书架收藏区)时用,自身不滚。纯 Dart 布局,Windows 安全。
class FeedView extends StatelessWidget {
  const FeedView({
    super.key,
    required this.layout,
    required this.itemCount,
    required this.cardBuilder,
    required this.tileBuilder,
    this.controller,
    this.footer,
    this.columns = 0,
    this.shrinkWrap = false,
    this.padding = const EdgeInsets.fromLTRB(14, 10, 14, 6),
  });

  final FeedLayout layout;
  final int itemCount;
  final Widget Function(BuildContext, int) cardBuilder; // 瀑布流/网格
  final Widget Function(BuildContext, int) tileBuilder; // 列表
  final ScrollController? controller;
  final Widget? footer;
  final int columns;
  final bool shrinkWrap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          final cols = columnsFor(c.maxWidth, columns);
          final Widget body;
          switch (layout) {
            case FeedLayout.masonry:
              body = SliverPadding(
                padding: padding,
                sliver: SliverMasonryGrid.count(
                  crossAxisCount: cols,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 14,
                  childCount: itemCount,
                  itemBuilder: cardBuilder,
                ),
              );
            case FeedLayout.grid:
              body = SliverPadding(
                padding: padding,
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 14,
                    childAspectRatio: 0.60, // 封面 3:4 + 两行标题
                  ),
                  delegate: SliverChildBuilderDelegate(cardBuilder,
                      childCount: itemCount),
                ),
              );
            case FeedLayout.list:
              body = SliverPadding(
                padding: EdgeInsets.fromLTRB(
                    padding.left, padding.top, padding.right, padding.bottom),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(tileBuilder,
                      childCount: itemCount),
                ),
              );
          }
          return CustomScrollView(
            controller: controller,
            shrinkWrap: shrinkWrap,
            physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
            slivers: [
              body,
              if (footer != null) SliverToBoxAdapter(child: footer!),
            ],
          );
        },
      );
}
