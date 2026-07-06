import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

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

/// 瀑布流信息流:接管一个 [CustomScrollView],复用外部 [controller] 做无限滚动,
/// 底部挂 [footer]。[itemBuilder] 返回整张卡(封面用 [aspectForId] 决定的比例)。
/// 纯 Dart 布局,Windows 安全。
class MasonryFeed extends StatelessWidget {
  const MasonryFeed({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.controller,
    required this.footer,
    this.columns = 0,
    this.padding = const EdgeInsets.fromLTRB(14, 10, 14, 6),
    this.crossAxisSpacing = 12,
    this.mainAxisSpacing = 14,
  });

  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final ScrollController controller;
  final Widget footer;
  final int columns;
  final EdgeInsets padding;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          final cols = columnsFor(c.maxWidth, columns);
          return CustomScrollView(
            controller: controller,
            slivers: [
              SliverPadding(
                padding: padding,
                sliver: SliverMasonryGrid.count(
                  crossAxisCount: cols,
                  crossAxisSpacing: crossAxisSpacing,
                  mainAxisSpacing: mainAxisSpacing,
                  childCount: itemCount,
                  itemBuilder: itemBuilder,
                ),
              ),
              SliverToBoxAdapter(child: footer),
            ],
          );
        },
      );
}
