import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/novel/reader/novel_paginator.dart';
import '../../core/novel/reader/novel_render_document.dart';

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
