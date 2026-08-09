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
              child: CustomPaint(
                painter: NovelNativePagePainter(
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
        child: SingleChildScrollView(
          key: const Key('novel-native-scroll-view'),
          controller: widget.controller.scrollController,
          physics: const ClampingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: math.max(0, leaf.left),
            ),
            child: ColoredBox(
              key: const Key('novel-page-paper-color'),
              color: widget.pageColor,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final slice in slices)
                    RepaintBoundary(
                      child: SizedBox(
                        width: leaf.width,
                        height: slice.height,
                        child: CustomPaint(
                          painter: NovelNativePagePainter(
                            page: slice.page,
                            pageColor: widget.pageColor,
                            textColor: widget.textColor,
                            showPageNumber: false,
                            innerEdge: null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NovelNativePagePainter extends CustomPainter {
  const NovelNativePagePainter({
    required this.page,
    required this.pageColor,
    required this.textColor,
    required this.showPageNumber,
    required this.innerEdge,
  });

  final NovelPageLayout page;
  final Color pageColor;
  final Color textColor;
  final bool showPageNumber;
  final Alignment? innerEdge;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = pageColor);
    for (final fragment in page.fragments) {
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
    if (innerEdge != null) _paintInnerEdge(canvas, size);
    if (showPageNumber) _paintPageNumber(canvas, size);
  }

  void _paintText(Canvas canvas, NovelPageFragment fragment) {
    final painter = TextPainter(
      text: TextSpan(
        text: fragment.displayText,
        style: fragment.textStyle.copyWith(color: textColor),
      ),
      textAlign: fragment.textAlign,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: fragment.width);
    painter.paint(canvas, fragment.offset);
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
  }

  @override
  bool shouldRepaint(covariant NovelNativePagePainter oldDelegate) {
    return oldDelegate.page != page ||
        oldDelegate.pageColor != pageColor ||
        oldDelegate.textColor != textColor ||
        oldDelegate.showPageNumber != showPageNumber ||
        oldDelegate.innerEdge != innerEdge;
  }
}
