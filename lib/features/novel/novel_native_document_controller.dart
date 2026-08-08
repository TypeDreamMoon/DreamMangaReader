import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/novel_library_store.dart';
import '../../core/novel/models.dart';
import '../../core/novel/reader/novel_font_store.dart';
import '../../core/novel/reader/novel_paginator.dart';
import '../../core/novel/reader/novel_page_turn_physics.dart';
import '../../core/novel/reader/novel_reader_data.dart';
import '../../core/novel/reader/novel_reader_models.dart';
import '../../core/novel/reader/novel_reader_theme.dart';
import '../../core/novel/reader/novel_render_document.dart';
import 'novel_document_view.dart';
import 'novel_native_page_view.dart';

class NovelNativeDocumentController extends ChangeNotifier
    implements NovelDocumentController {
  String _chapterId = '';
  NovelRenderDocument? _document;
  NovelReaderPreferences _preferences = const NovelReaderPreferences();
  NovelPaginationResult? _pagination;
  Size? _viewport;
  String _styleSignature = '';
  NovelLocator? _locator;
  int _spreadIndex = 0;
  List<NovelAnnotation> _annotations = const [];
  double _rasterDevicePixelRatio = 1;
  int _rasterGeneration = 0;
  final Map<int, ui.Image> _pageImages = {};
  final Map<int, NovelPageFrame> _pageFrames = {};
  final Map<int, Future<NovelPageFrame?>> _captureJobs = {};

  NovelReaderPreferences get preferences => _preferences;
  NovelPaginationResult? get pagination => _pagination;
  int get spreadIndex => _spreadIndex;
  List<NovelAnnotation> get annotations => _annotations;
  int get cachedPageImageCount => _pageImages.length;

  ui.Image? pageImageFor(int spreadIndex) => _pageImages[spreadIndex];

  bool canTurn(NovelTurnDirection direction) {
    final pagination = _pagination;
    if (pagination == null) return false;
    return direction == NovelTurnDirection.next
        ? _spreadIndex < pagination.spreads.length - 1
        : _spreadIndex > 0;
  }

  @override
  ValueChanged<NovelReaderCommand>? onCommand;

  @override
  ValueChanged<NovelLocator>? onLocatorChanged;

  @override
  ValueChanged<NovelSelection?>? onSelectionChanged;

  @override
  ValueChanged<bool>? onCaptureStateChanged;

  @override
  ValueChanged<Set<String>>? onUnresolvedAnnotationsChanged;

  NovelPaginationResult? paginationFor(
    Size viewport, {
    double devicePixelRatio = 1,
  }) {
    final document = _document;
    if (document == null || viewport.width <= 0 || viewport.height <= 0) {
      return null;
    }
    final signature = _preferenceLayoutSignature(_preferences);
    final rasterDpr = devicePixelRatio.clamp(1.0, 2.0).toDouble();
    if (_pagination != null &&
        _viewport == viewport &&
        _styleSignature == signature &&
        _rasterDevicePixelRatio == rasterDpr) {
      return _pagination;
    }
    final restore = _currentLocator();
    final profile = novelReaderThemeProfile(
      _preferences.theme,
      foregroundOverrideArgb: _preferences.foregroundArgb,
    );
    final result = NovelPaginator.paginate(
      document: document,
      viewport: viewport,
      style: NovelPageStyle(
        fontFamily: _flutterFontFamily(_preferences.fontFamily),
        fontSize: _preferences.fontSize,
        lineHeight: _preferences.lineHeight,
        paragraphSpacing: _preferences.paragraphSpacing,
        firstLineIndent: _preferences.firstLineIndent,
        pagePadding: EdgeInsets.fromLTRB(
          _preferences.horizontalMargin,
          _preferences.topMargin,
          _preferences.horizontalMargin,
          _preferences.bottomMargin,
        ),
        textColor: Color(profile.foregroundArgb),
        textAlign: _preferences.textAlignment == NovelTextAlignment.justify
            ? TextAlign.justify
            : TextAlign.start,
      ),
    );
    _pagination = result;
    _viewport = viewport;
    _styleSignature = signature;
    _rasterDevicePixelRatio = rasterDpr;
    _spreadIndex = _spreadForLocator(result, _locator ?? restore);
    _locator = _currentLocator();
    return result;
  }

  @override
  Future<void> loadChapter(
    String chapterId,
    NovelDocument document,
    NovelReaderPreferences preferences,
  ) async {
    _chapterId = chapterId;
    _preferences = preferences;
    _document = NovelRenderDocumentParser.parse(document);
    _locator = NovelLocator(chapterId: chapterId);
    _spreadIndex = 0;
    _invalidateLayout();
    notifyListeners();
  }

  @override
  Future<NovelLocator> captureLocator() async {
    return _currentLocator() ?? NovelLocator(chapterId: _chapterId);
  }

  @override
  Future<NovelPageMetrics> pageMetrics() async {
    final pagination = _pagination;
    if (pagination == null) {
      return const NovelPageMetrics(
        pageCount: 1,
        currentPageIndex: 0,
        viewport: NovelViewport(width: 0, height: 0),
        layoutFingerprint: '',
      );
    }
    return NovelPageMetrics(
      pageCount: pagination.spreads.length,
      currentPageIndex: _spreadIndex,
      viewport: NovelViewport(
        width: pagination.viewport.width,
        height: pagination.viewport.height,
      ),
      layoutFingerprint: _rasterFingerprint(pagination),
      visibleTextLength: _visibleTextLength(pagination),
    );
  }

  @override
  Future<NovelPageFrame?> capturePage(int pageIndex) {
    final pagination = _pagination;
    if (pagination == null ||
        pageIndex < 0 ||
        pageIndex >= pagination.spreads.length) {
      return Future.value();
    }
    final cached = _pageFrames[pageIndex];
    if (cached != null && _pageImages.containsKey(pageIndex)) {
      return Future.value(cached);
    }
    final pending = _captureJobs[pageIndex];
    if (pending != null) return pending;
    final operation = _capturePage(pagination, pageIndex);
    _captureJobs[pageIndex] = operation;
    operation.whenComplete(() {
      if (identical(_captureJobs[pageIndex], operation)) {
        _captureJobs.remove(pageIndex);
      }
    });
    return operation;
  }

  Future<NovelPageFrame?> _capturePage(
    NovelPaginationResult pagination,
    int pageIndex,
  ) async {
    final generation = _rasterGeneration;
    final image = await _rasterizeSpread(pagination, pageIndex);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null || generation != _rasterGeneration) {
      image.dispose();
      return null;
    }
    final frame = NovelPageFrame(
      key: NovelPageKey(
        chapterId: _chapterId,
        pageIndex: pageIndex,
        layoutFingerprint: _rasterFingerprint(pagination),
      ),
      viewport: NovelViewport(
        width: pagination.viewport.width,
        height: pagination.viewport.height,
        devicePixelRatio: _rasterDevicePixelRatio,
      ),
      bytes: bytes.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      ),
    );
    _pageImages.remove(pageIndex)?.dispose();
    _pageImages[pageIndex] = image;
    _pageFrames[pageIndex] = frame;
    _trimRasterCache();
    return frame;
  }

  Future<void> preloadAroundCurrent() async {
    final pagination = _pagination;
    if (pagination == null) return;
    for (final index in [_spreadIndex - 1, _spreadIndex, _spreadIndex + 1]) {
      if (index >= 0 && index < pagination.spreads.length) {
        await capturePage(index);
      }
    }
    notifyListeners();
  }

  @override
  Future<void> showPage(int pageIndex) async {
    final pagination = _pagination;
    if (pagination == null || pagination.spreads.isEmpty) return;
    final target = pageIndex.clamp(0, pagination.spreads.length - 1);
    if (target == _spreadIndex) return;
    _spreadIndex = target;
    _publishPosition();
    unawaited(preloadAroundCurrent());
  }

  @override
  Future<void> restoreLocator(NovelLocator locator) async {
    if (locator.chapterId != _chapterId) return;
    _locator = locator;
    final pagination = _pagination;
    if (pagination != null) {
      _spreadIndex = _spreadForLocator(pagination, locator);
    }
    notifyListeners();
  }

  @override
  Future<void> applyPreferences(NovelReaderPreferences preferences) async {
    _locator = _currentLocator();
    _preferences = preferences;
    _invalidateLayout();
    notifyListeners();
  }

  @override
  Future<Set<String>> applyAnnotations(
    Iterable<NovelAnnotation> annotations,
  ) async {
    _annotations = List.unmodifiable(annotations);
    onUnresolvedAnnotationsChanged?.call(const {});
    notifyListeners();
    return const {};
  }

  @override
  Future<void> clearSelection() async {
    onSelectionChanged?.call(null);
  }

  @override
  Future<void> showSearchResult(NovelLocator locator) =>
      restoreLocator(locator);

  @override
  Future<bool> nextPage() async {
    final pagination = _pagination;
    if (pagination == null || _spreadIndex >= pagination.spreads.length - 1) {
      return false;
    }
    _spreadIndex++;
    _trimRasterCache();
    _publishPosition();
    unawaited(preloadAroundCurrent());
    return true;
  }

  @override
  Future<bool> previousPage() async {
    if (_pagination == null || _spreadIndex <= 0) return false;
    _spreadIndex--;
    _trimRasterCache();
    _publishPosition();
    unawaited(preloadAroundCurrent());
    return true;
  }

  void _publishPosition() {
    _locator = _currentLocator();
    final locator = _locator;
    if (locator != null) onLocatorChanged?.call(locator);
    notifyListeners();
  }

  NovelLocator? _currentLocator() {
    final pagination = _pagination;
    if (pagination == null || pagination.spreads.isEmpty) return _locator;
    final spread = pagination
        .spreads[_spreadIndex.clamp(0, pagination.spreads.length - 1)];
    final page = spread.leftPage ?? spread.rightPage;
    final fragment = page?.fragments
        .where((value) => value.sourceText.isNotEmpty)
        .firstOrNull;
    final fraction = pagination.spreads.length <= 1
        ? 0.0
        : _spreadIndex / (pagination.spreads.length - 1);
    return NovelLocator(
      chapterId: _chapterId,
      blockId: fragment?.blockId,
      charOffset: fragment?.sourceStart,
      fraction: fraction,
    );
  }

  int _spreadForLocator(
    NovelPaginationResult pagination,
    NovelLocator? locator,
  ) {
    if (pagination.spreads.isEmpty || locator == null) return 0;
    final page = pagination.pageIndexForLocator(locator);
    if (page != null) return pagination.spreadIndexForPage(page);
    return ((pagination.spreads.length - 1) * locator.fraction)
        .round()
        .clamp(0, pagination.spreads.length - 1);
  }

  int _visibleTextLength(NovelPaginationResult pagination) {
    if (pagination.spreads.isEmpty) return 0;
    final spread = pagination
        .spreads[_spreadIndex.clamp(0, pagination.spreads.length - 1)];
    return [spread.leftPage, spread.rightPage]
        .whereType<NovelPageLayout>()
        .expand((page) => page.fragments)
        .fold(0, (total, fragment) => total + fragment.sourceText.length);
  }

  void _invalidateLayout() {
    _clearRasterCache();
    _pagination = null;
    _viewport = null;
    _styleSignature = '';
  }

  String _rasterFingerprint(NovelPaginationResult pagination) =>
      '${pagination.layoutFingerprint}@${_rasterDevicePixelRatio.toStringAsFixed(2)}';

  Future<ui.Image> _rasterizeSpread(
    NovelPaginationResult pagination,
    int spreadIndex,
  ) async {
    final profile = novelReaderThemeProfile(
      _preferences.theme,
      foregroundOverrideArgb: _preferences.foregroundArgb,
    );
    final pageColor = Color(profile.backgroundArgb);
    final textColor = Color(profile.foregroundArgb);
    final canvasColor = Color(
      blendNovelReaderArgb(
        profile.backgroundArgb,
        profile.foregroundArgb,
        .045,
      ),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(_rasterDevicePixelRatio, _rasterDevicePixelRatio)
      ..drawRect(
        Offset.zero & pagination.viewport,
        Paint()..color = canvasColor,
      );
    final spread = pagination.spreads[spreadIndex];
    if (pagination.pagesPerSpread == 2) {
      final left = pagination.leafRects[0];
      final right = pagination.leafRects[1];
      canvas.drawRect(
        Rect.fromLTRB(left.right, 0, right.left, pagination.viewport.height),
        Paint()..color = textColor.withValues(alpha: .045),
      );
    }

    void paintLeaf(
      Rect rect,
      NovelPageLayout page,
      Alignment? innerEdge,
    ) {
      canvas.drawShadow(
        Path()..addRect(rect),
        Colors.black.withValues(alpha: .18),
        5,
        false,
      );
      canvas
        ..save()
        ..translate(rect.left, rect.top)
        ..clipRect(Offset.zero & rect.size);
      NovelNativePagePainter(
        page: page,
        pageColor: pageColor,
        textColor: textColor,
        showPageNumber: _preferences.showPageNumber,
        innerEdge: innerEdge,
      ).paint(canvas, rect.size);
      canvas.restore();
    }

    if (pagination.pagesPerSpread == 2 && spread.leftPage != null) {
      paintLeaf(
        pagination.leafRects[0],
        spread.leftPage!,
        Alignment.centerRight,
      );
    }
    if (spread.rightPage != null) {
      paintLeaf(
        pagination.leafRects.last,
        spread.rightPage!,
        pagination.pagesPerSpread == 2 ? Alignment.centerLeft : null,
      );
    }
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(
        (pagination.viewport.width * _rasterDevicePixelRatio).ceil(),
        (pagination.viewport.height * _rasterDevicePixelRatio).ceil(),
      );
    } finally {
      picture.dispose();
    }
  }

  void _trimRasterCache() {
    final retained = {_spreadIndex - 1, _spreadIndex, _spreadIndex + 1};
    final stale = _pageImages.keys
        .where((index) => !retained.contains(index))
        .toList(growable: false);
    for (final index in stale) {
      _pageImages.remove(index)?.dispose();
      _pageFrames.remove(index);
    }
  }

  void _clearRasterCache() {
    _rasterGeneration++;
    for (final image in _pageImages.values) {
      image.dispose();
    }
    _pageImages.clear();
    _pageFrames.clear();
    _captureJobs.clear();
  }

  @override
  void dispose() {
    _clearRasterCache();
    super.dispose();
  }
}

class NovelNativeDocumentView extends StatelessWidget {
  const NovelNativeDocumentView({
    super.key,
    required this.controller,
  });

  final NovelNativeDocumentController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final profile = novelReaderThemeProfile(
          controller.preferences.theme,
          foregroundOverrideArgb: controller.preferences.foregroundArgb,
        );
        final pageColor = Color(profile.backgroundArgb);
        final canvasColor = Color(
          blendNovelReaderArgb(
            profile.backgroundArgb,
            profile.foregroundArgb,
            .045,
          ),
        );
        return LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final pagination = controller.paginationFor(
              size,
              devicePixelRatio: View.of(context).devicePixelRatio,
            );
            if (pagination == null) {
              return ColoredBox(color: pageColor);
            }
            return NovelNativePageView(
              pagination: pagination,
              spreadIndex: controller.spreadIndex,
              canvasColor: canvasColor,
              pageColor: pageColor,
              textColor: Color(profile.foregroundArgb),
              showPageNumbers: controller.preferences.showPageNumber,
            );
          },
        );
      },
    );
  }
}

String _preferenceLayoutSignature(NovelReaderPreferences value) => [
      value.fontFamily,
      value.fontSize,
      value.lineHeight,
      value.paragraphSpacing,
      value.horizontalMargin,
      value.topMargin,
      value.bottomMargin,
      value.firstLineIndent,
      value.textAlignment.name,
      value.theme.name,
      value.foregroundArgb,
    ].join('|');

String? _flutterFontFamily(String id) => switch (normalizeNovelFontId(id)) {
      NovelFontIds.notoSerifSc => 'DMRNotoSerifSC',
      NovelFontIds.lxgwWenKai => 'DMRLXGWWenKai',
      _ => null,
    };

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
