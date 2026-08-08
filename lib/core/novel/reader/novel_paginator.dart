import 'dart:math' as math;
import 'package:flutter/painting.dart';

import '../models.dart';
import 'novel_render_document.dart';

class NovelPageStyle {
  const NovelPageStyle({
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.firstLineIndent,
    required this.pagePadding,
    this.fontFamily,
    this.textColor = const Color(0xff202124),
    this.textAlign = TextAlign.justify,
    this.wideViewportThreshold = 900,
    this.spreadGutter = 28,
    this.maxLeafWidth = 620,
  });

  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final double firstLineIndent;
  final EdgeInsets pagePadding;
  final String? fontFamily;
  final Color textColor;
  final TextAlign textAlign;
  final double wideViewportThreshold;
  final double spreadGutter;
  final double maxLeafWidth;
}

class NovelPageFragment {
  const NovelPageFragment({
    required this.blockId,
    required this.blockKind,
    required this.sourceStart,
    required this.sourceEnd,
    required this.sourceText,
    required this.displayText,
    required this.offset,
    required this.width,
    required this.height,
    required this.textStyle,
    required this.textAlign,
    this.headingLevel,
    this.marker,
    this.imageSource,
    this.imageAlt,
  });

  final String blockId;
  final NovelRenderBlockKind blockKind;
  final int sourceStart;
  final int sourceEnd;
  final String sourceText;
  final String displayText;
  final Offset offset;
  final double width;
  final double height;
  final TextStyle textStyle;
  final TextAlign textAlign;
  final int? headingLevel;
  final String? marker;
  final String? imageSource;
  final String? imageAlt;
}

class NovelPageLayout {
  NovelPageLayout({
    required this.pageIndex,
    required List<NovelPageFragment> fragments,
  }) : fragments = List.unmodifiable(fragments);

  final int pageIndex;
  final List<NovelPageFragment> fragments;
}

class NovelBookSpread {
  const NovelBookSpread({
    required this.spreadIndex,
    required this.leftPage,
    required this.rightPage,
  });

  final int spreadIndex;
  final NovelPageLayout? leftPage;
  final NovelPageLayout? rightPage;
}

class NovelPaginationResult {
  NovelPaginationResult({
    required this.viewport,
    required this.pagesPerSpread,
    required List<Rect> leafRects,
    required List<NovelPageLayout> pages,
    required List<NovelBookSpread> spreads,
    required this.layoutFingerprint,
  })  : leafRects = List.unmodifiable(leafRects),
        pages = List.unmodifiable(pages),
        spreads = List.unmodifiable(spreads);

  final Size viewport;
  final int pagesPerSpread;
  final List<Rect> leafRects;
  final List<NovelPageLayout> pages;
  final List<NovelBookSpread> spreads;
  final String layoutFingerprint;

  int? pageIndexForLocator(NovelLocator locator) {
    final blockId = locator.blockId;
    if (blockId == null) {
      if (pages.isEmpty) return null;
      return ((pages.length - 1) * locator.fraction).round();
    }
    final offset = locator.charOffset ?? 0;
    for (final page in pages) {
      for (final fragment in page.fragments) {
        if (fragment.blockId != blockId) continue;
        if (offset >= fragment.sourceStart && offset <= fragment.sourceEnd) {
          return page.pageIndex;
        }
      }
    }
    return null;
  }

  int spreadIndexForPage(int pageIndex) {
    if (pages.isEmpty) return 0;
    final safe = pageIndex.clamp(0, pages.length - 1);
    return safe ~/ pagesPerSpread;
  }
}

class NovelPaginator {
  NovelPaginator._();

  static NovelPaginationResult paginate({
    required NovelRenderDocument document,
    required Size viewport,
    required NovelPageStyle style,
  }) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      throw ArgumentError.value(viewport, 'viewport', 'Must be positive.');
    }
    final geometry = _PageGeometry.resolve(viewport, style);
    final contentWidth =
        geometry.leafRects.first.width - style.pagePadding.horizontal;
    final contentHeight =
        geometry.leafRects.first.height - style.pagePadding.vertical;
    if (contentWidth <= 0 || contentHeight <= 0) {
      throw ArgumentError.value(
        style.pagePadding,
        'style.pagePadding',
        'Leaves must have a positive content area.',
      );
    }

    final pages = <NovelPageLayout>[];
    var builder = _PageBuilder(index: 0, contentHeight: contentHeight);

    void finishPage() {
      pages.add(builder.build());
      builder = _PageBuilder(
        index: pages.length,
        contentHeight: contentHeight,
      );
    }

    for (final block in document.blocks) {
      if (block.kind == NovelRenderBlockKind.spacer) {
        final height = style.fontSize * style.lineHeight;
        if (!builder.canFit(height) && builder.fragments.isNotEmpty) {
          finishPage();
        }
        builder.advance(math.min(height, builder.remainingHeight));
        continue;
      }
      if (block.kind == NovelRenderBlockKind.image) {
        final height = math.min(contentHeight, contentWidth * .64);
        if (!builder.canFit(height) && builder.fragments.isNotEmpty) {
          finishPage();
        }
        builder.add(NovelPageFragment(
          blockId: block.id,
          blockKind: block.kind,
          sourceStart: 0,
          sourceEnd: 0,
          sourceText: '',
          displayText: block.imageAlt ?? '',
          offset: Offset(
            style.pagePadding.left,
            style.pagePadding.top + builder.y,
          ),
          width: contentWidth,
          height: math.min(height, builder.remainingHeight),
          textStyle: _textStyle(block, style),
          textAlign: TextAlign.center,
          imageSource: block.imageSource,
          imageAlt: block.imageAlt,
        ));
        continue;
      }
      if (block.kind == NovelRenderBlockKind.separator) {
        const height = 28.0;
        if (!builder.canFit(height) && builder.fragments.isNotEmpty) {
          finishPage();
        }
        builder.add(NovelPageFragment(
          blockId: block.id,
          blockKind: block.kind,
          sourceStart: 0,
          sourceEnd: 0,
          sourceText: '',
          displayText: '',
          offset: Offset(
            style.pagePadding.left,
            style.pagePadding.top + builder.y,
          ),
          width: contentWidth,
          height: math.min(height, builder.remainingHeight),
          textStyle: _textStyle(block, style),
          textAlign: TextAlign.center,
        ));
        continue;
      }

      final source = block.plainText;
      var sourceOffset = 0;
      while (sourceOffset < source.length) {
        final textStyle = _textStyle(block, style);
        final firstFragment = sourceOffset == 0;
        final prefix = firstFragment ? _prefixFor(block, style) : '';
        final minimumLineHeight = textStyle.fontSize! * style.lineHeight;
        if (builder.remainingHeight + .01 < minimumLineHeight &&
            builder.fragments.isNotEmpty) {
          finishPage();
        }
        final availableHeight = builder.remainingHeight;
        var count = _largestFittingCodeUnitCount(
          source.substring(sourceOffset),
          prefix: prefix,
          width: contentWidth,
          maxHeight: availableHeight,
          style: textStyle,
          align: _alignmentFor(block, style),
        );
        if (count == 0) {
          if (builder.fragments.isNotEmpty) {
            finishPage();
            continue;
          }
          count = _firstCodePointLength(source, sourceOffset);
        }
        final end = sourceOffset + count;
        final sourceText = source.substring(sourceOffset, end);
        final displayText = '$prefix$sourceText';
        final painter = _layoutText(
          displayText,
          textStyle,
          contentWidth,
          _alignmentFor(block, style),
        );
        builder.add(NovelPageFragment(
          blockId: block.id,
          blockKind: block.kind,
          sourceStart: sourceOffset,
          sourceEnd: end,
          sourceText: sourceText,
          displayText: displayText,
          offset: Offset(
            style.pagePadding.left,
            style.pagePadding.top + builder.y,
          ),
          width: contentWidth,
          height: painter.height,
          textStyle: textStyle,
          textAlign: _alignmentFor(block, style),
          headingLevel: block.headingLevel,
          marker: block.marker,
        ));
        sourceOffset = end;
        if (sourceOffset < source.length) finishPage();
      }
      if (style.paragraphSpacing > 0) {
        if (builder.canFit(style.paragraphSpacing)) {
          builder.advance(style.paragraphSpacing);
        } else if (builder.fragments.isNotEmpty) {
          finishPage();
        }
      }
    }
    if (builder.fragments.isNotEmpty || pages.isEmpty) finishPage();

    final spreads = <NovelBookSpread>[];
    if (geometry.pagesPerSpread == 1) {
      for (final page in pages) {
        spreads.add(NovelBookSpread(
          spreadIndex: spreads.length,
          leftPage: null,
          rightPage: page,
        ));
      }
    } else {
      for (var index = 0; index < pages.length; index += 2) {
        spreads.add(NovelBookSpread(
          spreadIndex: spreads.length,
          leftPage: pages[index],
          rightPage: index + 1 < pages.length ? pages[index + 1] : null,
        ));
      }
    }

    final fingerprint = [
      viewport.width.toStringAsFixed(2),
      viewport.height.toStringAsFixed(2),
      geometry.pagesPerSpread,
      style.fontFamily ?? '',
      style.fontSize,
      style.lineHeight,
      style.paragraphSpacing,
      style.firstLineIndent,
      style.pagePadding,
      style.textAlign,
      for (final block in document.blocks)
        '${block.id}:${block.plainText.length}',
    ].join('|');
    return NovelPaginationResult(
      viewport: viewport,
      pagesPerSpread: geometry.pagesPerSpread,
      leafRects: geometry.leafRects,
      pages: pages,
      spreads: spreads,
      layoutFingerprint: fingerprint,
    );
  }

  static TextStyle _textStyle(
    NovelRenderBlock block,
    NovelPageStyle style,
  ) {
    final multiplier = block.kind == NovelRenderBlockKind.heading
        ? switch (block.headingLevel ?? 2) {
            1 => 1.55,
            2 => 1.38,
            3 => 1.24,
            _ => 1.12,
          }
        : 1.0;
    return TextStyle(
      color: style.textColor,
      fontFamily: style.fontFamily,
      fontSize: style.fontSize * multiplier,
      height: style.lineHeight,
      fontWeight: block.kind == NovelRenderBlockKind.heading
          ? FontWeight.w600
          : FontWeight.normal,
      fontStyle: block.kind == NovelRenderBlockKind.quote
          ? FontStyle.italic
          : FontStyle.normal,
      letterSpacing: 0,
    );
  }

  static TextAlign _alignmentFor(
    NovelRenderBlock block,
    NovelPageStyle style,
  ) {
    if (block.kind == NovelRenderBlockKind.heading) return TextAlign.start;
    if (block.kind == NovelRenderBlockKind.code) return TextAlign.start;
    return style.textAlign;
  }

  static String _prefixFor(NovelRenderBlock block, NovelPageStyle style) {
    final marker = block.marker == null ? '' : '${block.marker} ';
    if (block.kind != NovelRenderBlockKind.paragraph) return marker;
    final full = style.firstLineIndent.floor();
    final fraction = style.firstLineIndent - full;
    return '$marker${List.filled(full, '\u3000').join()}'
        '${fraction >= .5 ? '\u2002' : ''}';
  }

  static int _largestFittingCodeUnitCount(
    String source, {
    required String prefix,
    required double width,
    required double maxHeight,
    required TextStyle style,
    required TextAlign align,
  }) {
    if (source.isEmpty || maxHeight <= 0) return 0;
    var low = 1;
    var high = source.length;
    var best = 0;
    while (low <= high) {
      var middle = (low + high) ~/ 2;
      if (middle < source.length &&
          _isLowSurrogate(source.codeUnitAt(middle))) {
        middle--;
      }
      if (middle <= 0) middle = 1;
      final painter = _layoutText(
        '$prefix${source.substring(0, middle)}',
        style,
        width,
        align,
      );
      if (painter.height <= maxHeight + .01) {
        best = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (best < source.length &&
        best > 0 &&
        _isLowSurrogate(source.codeUnitAt(best))) {
      best--;
    }
    return best;
  }

  static TextPainter _layoutText(
    String text,
    TextStyle style,
    double width,
    TextAlign align,
  ) {
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: width);
  }

  static int _firstCodePointLength(String source, int offset) {
    final first = source.codeUnitAt(offset);
    return _isHighSurrogate(first) && offset + 1 < source.length ? 2 : 1;
  }

  static bool _isHighSurrogate(int value) => value >= 0xd800 && value <= 0xdbff;
  static bool _isLowSurrogate(int value) => value >= 0xdc00 && value <= 0xdfff;
}

class _PageBuilder {
  _PageBuilder({required this.index, required this.contentHeight});

  final int index;
  final double contentHeight;
  final List<NovelPageFragment> fragments = [];
  double y = 0;

  double get remainingHeight => math.max(0, contentHeight - y);

  bool canFit(double height) => height <= remainingHeight + .01;

  void add(NovelPageFragment fragment) {
    fragments.add(fragment);
    y += fragment.height;
  }

  void advance(double height) {
    y += height;
  }

  NovelPageLayout build() =>
      NovelPageLayout(pageIndex: index, fragments: fragments);
}

class _PageGeometry {
  const _PageGeometry({
    required this.pagesPerSpread,
    required this.leafRects,
  });

  final int pagesPerSpread;
  final List<Rect> leafRects;

  static _PageGeometry resolve(Size viewport, NovelPageStyle style) {
    final usesBookSpread = viewport.width >= style.wideViewportThreshold &&
        viewport.width > viewport.height;
    if (!usesBookSpread) {
      final width = math.min(viewport.width, style.maxLeafWidth);
      final left = (viewport.width - width) / 2;
      return _PageGeometry(
        pagesPerSpread: 1,
        leafRects: [Rect.fromLTWH(left, 0, width, viewport.height)],
      );
    }
    final totalWidth = math.min(
      viewport.width,
      style.maxLeafWidth * 2 + style.spreadGutter,
    );
    final leafWidth = (totalWidth - style.spreadGutter) / 2;
    final left = (viewport.width - totalWidth) / 2;
    return _PageGeometry(
      pagesPerSpread: 2,
      leafRects: [
        Rect.fromLTWH(left, 0, leafWidth, viewport.height),
        Rect.fromLTWH(
          left + leafWidth + style.spreadGutter,
          0,
          leafWidth,
          viewport.height,
        ),
      ],
    );
  }
}
