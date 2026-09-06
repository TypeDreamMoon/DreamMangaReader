import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/novel/reader/novel_page_turn_physics.dart';
import '../../core/novel/reader/novel_paginator.dart';
import '../../core/novel/reader/novel_render_document.dart';
import 'novel_native_document_controller.dart';

class NovelNativePageView extends StatelessWidget {
  const NovelNativePageView({
    super.key,
    required this.pagination,
    required this.spreadIndex,
    required this.canvasColor,
    required this.pageColor,
    required this.textColor,
    this.showPageNumbers = true,
  });

  final NovelPaginationResult pagination;
  final int spreadIndex;
  final Color canvasColor;
  final Color pageColor;
  final Color textColor;
  final bool showPageNumbers;

  @override
  Widget build(BuildContext context) {
    if (pagination.spreads.isEmpty) {
      return ColoredBox(
        key: const Key('novel-page-canvas-color'),
        color: canvasColor,
      );
    }
    final index = spreadIndex.clamp(0, pagination.spreads.length - 1);
    final spread = pagination.spreads[index];
    return ColoredBox(
      key: const Key('novel-page-canvas-color'),
      color: canvasColor,
      child: Stack(
        key: const Key('novel-native-page-view'),
        fit: StackFit.expand,
        children: [
          if (pagination.pagesPerSpread == 2) _buildSpine(),
          if (pagination.pagesPerSpread == 2 && spread.leftPage != null)
            _positionedLeaf(
              key: const Key('novel-leaf-left'),
              rect: pagination.leafRects[0],
              page: spread.leftPage!,
              innerEdge: Alignment.centerRight,
            ),
          if (spread.rightPage != null)
            _positionedLeaf(
              key: const Key('novel-leaf-right'),
              rect: pagination.leafRects.last,
              page: spread.rightPage!,
              innerEdge:
                  pagination.pagesPerSpread == 2 ? Alignment.centerLeft : null,
            ),
        ],
      ),
    );
  }

  Widget _buildSpine() {
    final left = pagination.leafRects[0];
    final right = pagination.leafRects[1];
    return Positioned.fromRect(
      rect:
          Rect.fromLTRB(left.right, 0, right.left, pagination.viewport.height),
      child: IgnorePointer(
        child: Container(
          key: const Key('novel-book-spine'),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              textColor.withValues(alpha: .035),
              canvasColor,
            ),
            boxShadow: [
              BoxShadow(
                color: textColor.withValues(alpha: .12),
                blurRadius: 12,
                spreadRadius: -5,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _positionedLeaf({
    required Key key,
    required Rect rect,
    required NovelPageLayout page,
    required Alignment? innerEdge,
  }) {
    final label = page.fragments
        .map((fragment) => fragment.sourceText)
        .where((text) => text.isNotEmpty)
        .join('\n');
    return Positioned.fromRect(
      rect: rect,
      child: Semantics(
        key: key,
        container: true,
        explicitChildNodes: false,
        label: label,
        value: '${page.pageIndex + 1}',
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .14),
                  blurRadius: 9,
                  spreadRadius: -4,
                ),
              ],
            ),
            child: ColoredBox(
              key: const Key('novel-page-paper-color'),
              color: pageColor,
              child: NovelNativePageCanvas(
                page: page,
                pageColor: pageColor,
                textColor: textColor,
                showPageNumber: showPageNumbers,
                innerEdge: innerEdge,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 滚动模式的画布:整章连成一列,由 [ScrollView] 负责滚动。
///
/// 分页渲染器只实现了「一屏一页」,选了上下滚动以后画面还是分页视图、拖拽被禁用,
/// 于是完全滚不动(issue #15)。这里复用同一套排版结果(滚动模式下整章排成一页),
/// 按内容真实高度铺开,并把滚动位置回报给控制器换算阅读进度。
class NovelNativeScrollView extends StatefulWidget {
  const NovelNativeScrollView({
    super.key,
    required this.controller,
    required this.pagination,
    required this.canvasColor,
    required this.pageColor,
    required this.textColor,
    this.onReachedEnd,
  });

  final NovelNativeDocumentController controller;
  final NovelPaginationResult pagination;
  final Color canvasColor;
  final Color pageColor;
  final Color textColor;

  /// 已经滚到底还继续往下拉 → 交给上层翻到下一章。
  final ValueChanged<NovelTurnDirection>? onReachedEnd;

  @override
  State<NovelNativeScrollView> createState() => _NovelNativeScrollViewState();
}

class _NovelNativeScrollViewState extends State<NovelNativeScrollView> {
  static const double _chapterFlipOverscroll = 96;

  double _overscroll = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyPending());
  }

  @override
  void didUpdateWidget(covariant NovelNativeScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.scrollController.removeListener(_onScroll);
      widget.controller.scrollController.addListener(_onScroll);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyPending());
  }

  @override
  void dispose() {
    widget.controller.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final scroll = widget.controller.scrollController;
    if (!scroll.hasClients) return;
    widget.controller.reportScroll(
      scroll.position.pixels,
      scroll.position.maxScrollExtent,
    );
  }

  void _applyPending() {
    if (!mounted) return;
    final target = widget.controller.takePendingScrollOffset();
    final scroll = widget.controller.scrollController;
    if (target == null || !scroll.hasClients) return;
    scroll.jumpTo(
      target.clamp(
        scroll.position.minScrollExtent,
        scroll.position.maxScrollExtent,
      ),
    );
  }

  bool _onNotification(ScrollNotification notification) {
    final handler = widget.onReachedEnd;
    if (handler == null) return false;
    if (notification is OverscrollNotification) {
      _overscroll += notification.overscroll;
      if (_overscroll >= _chapterFlipOverscroll) {
        _overscroll = 0;
        handler(NovelTurnDirection.next);
      } else if (_overscroll <= -_chapterFlipOverscroll) {
        _overscroll = 0;
        handler(NovelTurnDirection.previous);
      }
    } else if (notification is ScrollEndNotification) {
      _overscroll = 0;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final leaf = widget.pagination.leafRects.first;
    final slices = widget.controller.scrollSlices;
    return ColoredBox(
      key: const Key('novel-page-canvas-color'),
      color: widget.canvasColor,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onNotification,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: math.max(0, leaf.left)),
          child: ColoredBox(
            key: const Key('novel-page-paper-color'),
            color: widget.pageColor,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bands = novelScrollBands(
                  slices,
                  bandExtent: constraints.hasBoundedHeight
                      ? constraints.maxHeight
                      : novelScrollFallbackBandExtent,
                );
                return ListView.builder(
                  key: const Key('novel-native-scroll-view'),
                  controller: widget.controller.scrollController,
                  physics: const ClampingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  itemCount: bands.length,
                  // 带高就是真实高度，相加仍然等于切片总高。定位用的是绝对偏移
                  // (NovelScrollSlice.top)，不能交给 ListView 按平均子高去估算。
                  itemExtentBuilder: (index, _) =>
                      index < bands.length ? bands[index].height : 0,
                  itemBuilder: (context, index) {
                    final band = bands[index];
                    // 用 NovelNativePageCanvas 而不是裸 CustomPaint：TextPainter
                    // 缓存挂在这一带自己的 State 上，带被 ListView 回收时一起释放。
                    return NovelNativePageCanvas(
                      page: band.page,
                      pageColor: widget.pageColor,
                      textColor: widget.textColor,
                      showPageNumber: false,
                      innerEdge: null,
                      bandTop: band.top,
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 拿不到有界高度时的带高。
const double novelScrollFallbackBandExtent = 720;

/// 一屏高的正文带：属于 [page]，从页内 [top] 开始，高 [height]。
class NovelScrollBand {
  const NovelScrollBand({
    required this.page,
    required this.top,
    required this.height,
  });

  final NovelPageLayout page;
  final double top;
  final double height;
}

/// 把排版切片再切成一屏高的带。
///
/// 滚动模式的排版是「整章一页」，切片通常就一个，高度是整章的高度。老实现
/// 把它一次性放进 SingleChildScrollView + Column：一个几万像素高的 RepaintBoundary，
/// 每帧把整章所有 fragment 重画一遍 —— 大章节直接爆内存、掉帧。切成带以后，
/// [ListView] 只构建可见的那几带，painter 也只画落在带内的 fragment，而滚动偏移
/// 与 locator 语义一点没变。
///
/// [bandExtent] 只是上限：一个切片内的带高均分到一样，而不是“前面满格、最后一带留
/// 零头”。因为 `SliverVariedExtentList` 估算可滚总长时把子项当成等高，留了零头就会把
/// maxScrollExtent 多算一截 —— 滚动到底会多出一块空白，进度也永远到不了 100%。
List<NovelScrollBand> novelScrollBands(
  List<NovelScrollSlice> slices, {
  required double bandExtent,
}) {
  final extent = bandExtent.isFinite && bandExtent > 1
      ? bandExtent
      : novelScrollFallbackBandExtent;
  final bands = <NovelScrollBand>[];
  for (final slice in slices) {
    if (slice.height <= 0) continue;
    final count = math.max(1, (slice.height / extent).ceil());
    final height = slice.height / count;
    for (var index = 0; index < count; index++) {
      bands.add(NovelScrollBand(
        page: slice.page,
        top: index * height,
        height: height,
      ));
    }
  }
  return List.unmodifiable(bands);
}

/// 一页正文的画布。
///
/// [TextPainter] 缓存挂在 State 上：翻页、列表回收或页面离开视图时随 State 一起
/// `dispose()`。此前 painter 每帧给每个 fragment 新建一个 TextPainter 又从不释放，
/// 而 TextPainter 背后是 engine 侧的 Paragraph —— 滚一章就是几千个句柄的原生泄漏。
class NovelNativePageCanvas extends StatefulWidget {
  const NovelNativePageCanvas({
    super.key,
    required this.page,
    required this.pageColor,
    required this.textColor,
    required this.showPageNumber,
    required this.innerEdge,
    this.bandTop = 0,
  });

  final NovelPageLayout page;
  final Color pageColor;
  final Color textColor;
  final bool showPageNumber;
  final Alignment? innerEdge;

  /// 只画页内从 [bandTop] 起、高度为画布高度的那一段，坐标随之上移。
  ///
  /// 分页模式总是 0（一页就是一屏）；滚动模式把整章排成一页，靠它把一页拆成
  /// 多带懒渲染。
  final double bandTop;

  @override
  State<NovelNativePageCanvas> createState() => _NovelNativePageCanvasState();
}

class _NovelNativePageCanvasState extends State<NovelNativePageCanvas> {
  final NovelPageTextCache _textCache = NovelPageTextCache();

  @override
  void dispose() {
    _textCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: NovelNativePagePainter(
        page: widget.page,
        pageColor: widget.pageColor,
        textColor: widget.textColor,
        showPageNumber: widget.showPageNumber,
        innerEdge: widget.innerEdge,
        bandTop: widget.bandTop,
        textCache: _textCache,
      ),
    );
  }
}

/// 页内 [TextPainter] 的生命周期容器。
///
/// 一个缓存只服务一页：换页或换文字色就整批释放重建，所以既不会无限增长，也不会
/// 把上一页的 Paragraph 留在内存里。
class NovelPageTextCache {
  final Map<NovelPageFragment, TextPainter> _painters = Map.identity();
  NovelPageLayout? _page;
  Color? _color;

  int get length => _painters.length;

  TextPainter painterFor({
    required NovelPageLayout page,
    required NovelPageFragment fragment,
    required Color color,
  }) {
    if (!identical(_page, page) || _color != color) {
      _releaseAll();
      _page = page;
      _color = color;
    }
    return _painters[fragment] ??= novelFragmentTextPainter(fragment, color);
  }

  void dispose() {
    _releaseAll();
    _page = null;
    _color = null;
  }

  void _releaseAll() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
    _painters.clear();
  }
}

TextPainter novelFragmentTextPainter(NovelPageFragment fragment, Color color) {
  return TextPainter(
    text: TextSpan(
      text: fragment.displayText,
      style: fragment.textStyle.copyWith(color: color),
    ),
    textAlign: fragment.textAlign,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout(maxWidth: fragment.width);
}

class NovelNativePagePainter extends CustomPainter {
  const NovelNativePagePainter({
    required this.page,
    required this.pageColor,
    required this.textColor,
    required this.showPageNumber,
    required this.innerEdge,
    this.bandTop = 0,
    this.textCache,
  });

  final NovelPageLayout page;
  final Color pageColor;
  final Color textColor;
  final bool showPageNumber;
  final Alignment? innerEdge;

  /// 只画页内从 [bandTop] 起、高度为画布高度的那一段，坐标随之上移。
  ///
  /// 分页模式总是 0（一页就是一屏）；滚动模式把整章排成一页，靠它把一页拆成
  /// 多带懒渲染。
  final double bandTop;

  /// 由 [NovelNativePageCanvas] 提供的页级缓存；为空时 painter 自建自释放。
  final NovelPageTextCache? textCache;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = pageColor);
    final visibleBottom = bandTop + size.height;
    canvas.save();
    canvas.translate(0, -bandTop);
    for (final fragment in page.fragments) {
      if (fragment.offset.dy + fragment.height < bandTop ||
          fragment.offset.dy > visibleBottom) {
        continue;
      }
      switch (fragment.blockKind) {
        case NovelRenderBlockKind.image:
          _paintImagePlaceholder(canvas, fragment);
        case NovelRenderBlockKind.separator:
          _paintSeparator(canvas, fragment);
        case NovelRenderBlockKind.spacer:
          break;
        default:
          _paintText(canvas, fragment);
      }
    }
    canvas.restore();
    if (innerEdge != null) _paintInnerEdge(canvas, size);
    if (showPageNumber) _paintPageNumber(canvas, size);
  }

  void _paintText(Canvas canvas, NovelPageFragment fragment) {
    final cache = textCache;
    if (cache != null) {
      cache
          .painterFor(page: page, fragment: fragment, color: textColor)
          .paint(canvas, fragment.offset);
      return;
    }
    final painter = novelFragmentTextPainter(fragment, textColor);
    painter.paint(canvas, fragment.offset);
    painter.dispose();
  }

  void _paintImagePlaceholder(Canvas canvas, NovelPageFragment fragment) {
    final rect = Rect.fromLTWH(
      fragment.offset.dx,
      fragment.offset.dy,
      fragment.width,
      fragment.height,
    );
    canvas.drawRect(
      rect,
      Paint()..color = textColor.withValues(alpha: .055),
    );
    final alt = fragment.imageAlt?.trim();
    if (alt == null || alt.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: alt,
        style: TextStyle(color: textColor.withValues(alpha: .6), fontSize: 13),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, rect.width - 24));
    painter.paint(
      canvas,
      Offset(
        rect.center.dx - painter.width / 2,
        rect.center.dy - painter.height / 2,
      ),
    );
    painter.dispose();
  }

  void _paintSeparator(Canvas canvas, NovelPageFragment fragment) {
    final y = fragment.offset.dy + fragment.height / 2;
    canvas.drawLine(
      Offset(fragment.offset.dx + fragment.width * .28, y),
      Offset(fragment.offset.dx + fragment.width * .72, y),
      Paint()
        ..color = textColor.withValues(alpha: .22)
        ..strokeWidth = 1,
    );
  }

  void _paintInnerEdge(Canvas canvas, Size size) {
    final isLeftPage = innerEdge == Alignment.centerRight;
    final x = isLeftPage ? size.width : 0.0;
    canvas.drawRect(
      Rect.fromLTWH(isLeftPage ? x - 10 : x, 0, 10, size.height),
      Paint()
        ..color = textColor.withValues(alpha: .045)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
  }

  void _paintPageNumber(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(
        text: '${page.pageIndex + 1}',
        style: TextStyle(
          color: textColor.withValues(alpha: .55),
          fontSize: 11,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(
          (size.width - painter.width) / 2, size.height - painter.height - 9),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant NovelNativePagePainter oldDelegate) {
    return oldDelegate.page != page ||
        oldDelegate.pageColor != pageColor ||
        oldDelegate.textColor != textColor ||
        oldDelegate.showPageNumber != showPageNumber ||
        oldDelegate.innerEdge != innerEdge ||
        oldDelegate.bandTop != bandTop ||
        oldDelegate.textCache != textCache;
  }
}
