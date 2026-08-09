import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../ui/ui.dart';

/// 列表区的两种形态 —— 三个详情页确实各需要一种,骨架就把两种都认下来:
/// - [DetailListing.slivers]:跟着所在列一起滚(漫画章节的惰性 sliver、番剧分集网格);
/// - [DetailListing.fill]:自己滚、铺满可用高度(小说目录用 [ScrollablePositionedList]
///   跳到当前章,内部有 Expanded,必须拿到有界高度,塞进 sliver 会炸)。
class DetailListing {
  const DetailListing.slivers(this.slivers) : fill = null;
  const DetailListing.fill(Widget this.fill) : slivers = const [];

  final List<Widget> slivers;
  final Widget? fill;
}

/// 详情页的响应式骨架:
/// - 窄屏(< [breakpoint]):单列,信息段落在上、章节列表在下,一条滚动到底;
/// - 宽屏:双列,左 [infoColumnWidth] 信息、右列表,各自独立滚动。
///
/// 漫画/番剧/小说三个详情页原本各写一份 `_narrowBody`/`_wideBody`,断点、限宽、
/// 左列宽、底部留白、中间那条 [VerticalDivider]、给透明 AppBar 让位的顶部内边距
/// 全是同一组魔数,改一个就得记得改三处。现在只此一份。
class DetailBody extends StatelessWidget {
  const DetailBody({
    super.key,
    required this.info,
    required this.listing,
    this.narrowKey,
    this.wideKey,
  });

  /// 封面头 / 操作行 / 简介这类「信息段落」。窄屏排在列表上方,宽屏进左列。
  final List<Widget> info;

  /// 章节 / 分集 / 目录。[wide] 让调用方按布局给不同形态 —— 用 [DetailListing.fill]
  /// 的窄屏记得自己给个定高(单列里没有「剩余高度」可铺)。
  final DetailListing Function(bool wide) listing;

  /// 两种布局各自的定位 Key(测试用)。
  final Key? narrowKey;
  final Key? wideKey;

  /// 切双列的宽度阈值。
  static const double breakpoint = 760;
  static const double narrowMaxWidth = 820;
  static const double wideMaxWidth = 1180;
  static const double infoColumnWidth = 380;
  static const double bottomInset = 28;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) =>
            c.maxWidth >= breakpoint ? _wide(context) : _narrow(context),
      );

  Widget _narrow(BuildContext context) {
    final body = listing(false);
    return Center(
      child: ConstrainedBox(
        key: narrowKey,
        constraints: const BoxConstraints(maxWidth: narrowMaxWidth),
        // AppScrollView.custom:既能用 sliver(惰性长列表),又有桌面滚轮平滑滚动。
        child: AppScrollView.custom(
          custom: (controller) => CustomScrollView(
            controller: controller,
            slivers: [
              for (final section in info) SliverToBoxAdapter(child: section),
              if (body.fill case final fill?)
                SliverToBoxAdapter(child: fill)
              else
                ...body.slivers,
              const SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _wide(BuildContext context) {
    final p = context.palette;
    final body = listing(true);
    // 右列顶部让开透明 AppBar(内容延伸到它身后)。
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Center(
      child: ConstrainedBox(
        key: wideKey,
        constraints: const BoxConstraints(maxWidth: wideMaxWidth),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: infoColumnWidth,
              child: AppScrollView(
                padding: const EdgeInsets.only(bottom: bottomInset),
                children: info,
              ),
            ),
            VerticalDivider(width: 1, thickness: 1, color: p.line),
            // 自滚型(小说目录)铺满右列并自己管滚动;sliver 型跟着右列一起滚。
            if (body.fill case final fill?)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: fill,
                ),
              )
            else
              Expanded(
                child: AppScrollView.custom(
                  custom: (controller) => CustomScrollView(
                    controller: controller,
                    slivers: [
                      SliverToBoxAdapter(child: SizedBox(height: topInset)),
                      ...body.slivers,
                      const SliverToBoxAdapter(
                          child: SizedBox(height: bottomInset)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
