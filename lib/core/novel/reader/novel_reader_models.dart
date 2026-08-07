import 'dart:typed_data';

import '../models.dart';

enum NovelPageTurnMode { curl, cover, translate, none, scroll }

enum NovelTextAlignment { start, justify }

enum NovelReaderCommand { previous, next, toggleControls }

class NovelViewport {
  const NovelViewport({
    required this.width,
    required this.height,
    this.devicePixelRatio = 1,
  });

  final double width;
  final double height;
  final double devicePixelRatio;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NovelViewport &&
          width == other.width &&
          height == other.height &&
          devicePixelRatio == other.devicePixelRatio;

  @override
  int get hashCode => Object.hash(width, height, devicePixelRatio);
}

class NovelPageKey {
  const NovelPageKey({
    required this.chapterId,
    required this.pageIndex,
    required this.layoutFingerprint,
  });

  final String chapterId;
  final int pageIndex;
  final String layoutFingerprint;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NovelPageKey &&
          chapterId == other.chapterId &&
          pageIndex == other.pageIndex &&
          layoutFingerprint == other.layoutFingerprint;

  @override
  int get hashCode => Object.hash(chapterId, pageIndex, layoutFingerprint);
}

class NovelPageMetrics {
  const NovelPageMetrics({
    required this.pageCount,
    required this.currentPageIndex,
    required this.viewport,
    required this.layoutFingerprint,
    this.visibleTextLength = 0,
    this.fontLoadFailed = false,
  });

  final int pageCount;
  final int currentPageIndex;
  final NovelViewport viewport;
  final String layoutFingerprint;
  final int visibleTextLength;
  final bool fontLoadFailed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NovelPageMetrics &&
          pageCount == other.pageCount &&
          currentPageIndex == other.currentPageIndex &&
          viewport == other.viewport &&
          layoutFingerprint == other.layoutFingerprint &&
          visibleTextLength == other.visibleTextLength &&
          fontLoadFailed == other.fontLoadFailed;

  @override
  int get hashCode => Object.hash(
        pageCount,
        currentPageIndex,
        viewport,
        layoutFingerprint,
        visibleTextLength,
        fontLoadFailed,
      );
}

class NovelPageFrame {
  NovelPageFrame({
    required this.key,
    required this.viewport,
    required List<int> bytes,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final NovelPageKey key;
  final NovelViewport viewport;
  final Uint8List bytes;

  int get byteSize => bytes.length;
}

class NovelSelection {
  const NovelSelection({
    required this.text,
    required this.start,
    required this.end,
    this.rect,
  });

  final String text;
  final NovelLocator start;
  final NovelLocator end;
  final NovelSelectionRect? rect;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NovelSelection &&
          text == other.text &&
          start == other.start &&
          end == other.end &&
          rect == other.rect;

  @override
  int get hashCode => Object.hash(text, start, end, rect);
}

class NovelSelectionRect {
  const NovelSelectionRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NovelSelectionRect &&
          left == other.left &&
          top == other.top &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}
