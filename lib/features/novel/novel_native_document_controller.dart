import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/novel_library_store.dart';
import '../../core/novel/models.dart';
import '../../core/novel/reader/novel_background_store.dart';
import '../../core/novel/reader/novel_font_store.dart';
import '../../core/novel/reader/novel_paginator.dart';
import '../../core/novel/reader/novel_page_turn_physics.dart';
import '../../core/novel/reader/novel_reader_data.dart';
import '../../core/novel/reader/novel_reader_models.dart';
import '../../core/novel/reader/novel_reader_theme.dart';
import '../../core/novel/reader/novel_render_document.dart';
import 'novel_document_view.dart';
import 'novel_native_page_view.dart';

/// 内置纸张纹理的种子。与 WebView 渲染器取同一个，两边纹理才一致。
const int novelPaperTextureSeed = 20260807;

/// 主题自带纸张纹理时的内部标识。
const String _paperBackgroundKey = 'theme:paper';

class NovelNativeDocumentController extends ChangeNotifier
    implements NovelDocumentController, NovelPaginationSignals {
  NovelNativeDocumentController({
    NovelFontRegistry? fontRegistry,
    NovelBackgroundStore? backgroundStore,
  })  : _fontRegistry = fontRegistry ?? NovelFontRegistry.instance,
        _backgroundStore = backgroundStore ?? NovelBackgroundStore();

  final NovelFontRegistry _fontRegistry;
  bool _fontLoadFailed = false;

  final NovelBackgroundStore _backgroundStore;
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

  Completer<void>? _paginationWaiter;

  ui.Image? _backgroundImage;
  String? _backgroundKey;
  int _backgroundGeneration = 0;

  /// 背景图解码失败 / 文件不在了，请上层把这项设置清掉。
  VoidCallback? onBackgroundFallback;

  /// 铺在正文下面的背景（导入图或主题自带的纸张纹理）。
  NovelPageBackground? get pageBackground {
    final image = _backgroundImage;
    if (image == null) return null;
    return NovelPageBackground(
      image: image,
      // 纸张纹理本来就是一块瓷砖，拿「裁切」把 128px 噴成满屏只会糊成一片。
      fit: _backgroundKey == _paperBackgroundKey
          ? NovelBackgroundFit.tile
          : _preferences.backgroundFit,
      opacity: _preferences.textureStrength,
    );
  }

  NovelReaderPreferences get preferences => _preferences;
  NovelPaginationResult? get pagination => _pagination;

  @override
  bool get hasPagination => _pagination != null;

  @override
  Future<void> get paginationReady {
    if (_pagination != null) return Future<void>.value();
    return (_paginationWaiter ??= Completer<void>()).future;
  }
  int get spreadIndex => _spreadIndex;
  List<NovelAnnotation> get annotations => _annotations;
  int get cachedPageImageCount => _pageImages.length;

  // ——— 滚动模式 ———
  // 分页渲染器原本完全没有滚动实现:选了「上下滚动」以后画面还是分页视图,拖拽被
  // 禁用、滚轮和边缘点击直接跳章 —— 也就是 issue #15 里的「滚不动」。这里把整章按
  // 一列连续排版(排版仍复用 NovelPaginator,只是给一个足够高的版心),再交给
  // ScrollView 滚动;定位/进度由滚动偏移换算。

  final ScrollController scrollController = ScrollController();
  List<NovelScrollSlice> _scrollSlices = const [];
  double _scrollContentHeight = 0;
  double _scrollOffset = 0;
  double _scrollMaxExtent = 0;
  double? _pendingScrollOffset;

  bool get isScrollMode => _preferences.turnMode == NovelPageTurnMode.scroll;
  double get scrollContentHeight => _scrollContentHeight;
  List<NovelScrollSlice> get scrollSlices => _scrollSlices;

  /// 由视图在布局后取走一次:恢复进度 / 换章时要跳到的滚动位置。
  double? takePendingScrollOffset() {
    final value = _pendingScrollOffset;
    _pendingScrollOffset = null;
    return value;
  }

  /// 视图上报滚动位置。进度写盘走 [onLocatorChanged],这里只在**跨过千分之二**时
  /// 才发布 —— 每一帧都写一次会把主线程钉在 setState + 持久化上(issue #17 的卡顿)。
  void reportScroll(double offset, double maxExtent) {
    _scrollMaxExtent = maxExtent;
    final previous = _scrollFraction;
    _scrollOffset = offset;
    if ((_scrollFraction - previous).abs() < .002 &&
        offset > 0 &&
        offset < maxExtent) {
      return;
    }
    _locator = _currentLocator();
    final locator = _locator;
    if (locator != null) onLocatorChanged?.call(locator);
  }

  double get _scrollFraction => _scrollMaxExtent <= 0
      ? 0
      : (_scrollOffset / _scrollMaxExtent).clamp(0.0, 1.0);

  /// 边缘点击 / 滚轮在滚动模式下滚一屏,而不是跳整章。返回 false 表示已经到头,
  /// 由调用方决定是否翻章。
  bool scrollByViewport(NovelTurnDirection direction, double viewportHeight) {
    if (!scrollController.hasClients || viewportHeight <= 0) return false;
    final position = scrollController.position;
    final step = viewportHeight * .9;
    final target = (position.pixels +
            (direction == NovelTurnDirection.next ? step : -step))
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) return false;
    unawaited(scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    ));
    return true;
  }

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

  Size? _requestedViewport;
  double? _requestedDevicePixelRatio;
  bool _paginationScheduled = false;
  bool _disposed = false;

  /// build 期间**只读缓存**：命中就返回，没命中就把分页排到这一帧之后再做。
  ///
  /// 分页要给整章正文做 `TextPainter.layout()`，20 万字的章节要上百毫秒；原来它被
  /// 直接写在 `LayoutBuilder.builder` 里同步跑，于是改字号、转屏这些「顺手」的操作
  /// 都会把主线程钉住到 ANR。现在 build 只拿现成结果，算完再 [notifyListeners]。
  NovelPaginationResult? paginationFor(
    Size viewport, {
    double devicePixelRatio = 1,
  }) {
    final rasterDpr = devicePixelRatio.clamp(1.0, 2.0).toDouble();
    if (_isPaginationCurrent(viewport, rasterDpr)) return _pagination;
    _requestedViewport = viewport;
    _requestedDevicePixelRatio = rasterDpr;
    if (_document == null || viewport.width <= 0 || viewport.height <= 0) {
      return null;
    }
    if (!_paginationScheduled) {
      _paginationScheduled = true;
      scheduleMicrotask(_runScheduledPagination);
    }
    return null;
  }

  /// 同步跑完一次分页并返回结果。**不要在 build 里调用** —— 它是给测试、以及
  /// 「必须马上拿到版面」的非绘制路径准备的。
  NovelPaginationResult? ensurePagination(
    Size viewport, {
    double devicePixelRatio = 1,
  }) {
    final rasterDpr = devicePixelRatio.clamp(1.0, 2.0).toDouble();
    if (_isPaginationCurrent(viewport, rasterDpr)) return _pagination;
    _requestedViewport = viewport;
    _requestedDevicePixelRatio = rasterDpr;
    return _paginate(viewport, rasterDpr);
  }

  bool _isPaginationCurrent(Size viewport, double rasterDpr) {
    return _pagination != null &&
        _viewport == viewport &&
        _styleSignature == _preferenceLayoutSignature(_preferences) &&
        _rasterDevicePixelRatio == rasterDpr;
  }

  void _runScheduledPagination() {
    _paginationScheduled = false;
    if (_disposed) return;
    final viewport = _requestedViewport;
    final rasterDpr = _requestedDevicePixelRatio;
    if (viewport == null || rasterDpr == null) return;
    if (_isPaginationCurrent(viewport, rasterDpr)) return;
    if (_paginate(viewport, rasterDpr) == null) return;
    if (_disposed) return;
    notifyListeners();
  }

  NovelPaginationResult? _paginate(Size viewport, double rasterDpr) {
    final document = _document;
    if (document == null || viewport.width <= 0 || viewport.height <= 0) {
      return null;
    }
    final signature = _preferenceLayoutSignature(_preferences);
    final restore = _currentLocator();
    final profile = novelReaderThemeProfile(
      _preferences.theme,
      foregroundOverrideArgb: _preferences.foregroundArgb,
    );
    // 滚动模式:给一个足够高的版心,让整章排成一页,再按内容真实高度连续渲染。
    final layoutViewport = isScrollMode
        ? Size(viewport.width, _scrollLayoutHeight(document, viewport.width))
        : viewport;
    final result = NovelPaginator.paginate(
      document: document,
      viewport: layoutViewport,
      style: NovelPageStyle(
        fontFamily: _fontRegistry.familyFor(_preferences.fontFamily),
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
    final waiter = _paginationWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _rasterDevicePixelRatio = rasterDpr;
    if (isScrollMode) {
      _rebuildScrollSlices(result);
      _pendingScrollOffset = _scrollOffsetForLocator(_locator ?? restore);
      _scrollOffset = _pendingScrollOffset ?? 0;
      _spreadIndex = 0;
    } else {
      _scrollSlices = const [];
      _scrollContentHeight = 0;
      _spreadIndex = _spreadForLocator(result, _locator ?? restore);
    }
    _locator = _currentLocator();
    return result;
  }

  double _scrollLayoutHeight(NovelRenderDocument document, double width) {
    final characters = document.blocks
        .fold<int>(0, (total, block) => total + block.plainText.length);
    final lineHeight = _preferences.fontSize * _preferences.lineHeight;
    // 中日韩一行的字数约等于「版心宽 / 字号」,拉丁文只会更多 —— 少估每行字数 =
    // 多估总高度,而多估在这里是安全的(排不满不会出问题,排不下才会被切成第二页)。
    final perLine = math.max(1, width ~/ math.max(1.0, _preferences.fontSize));
    final lines = (characters / perLine).ceil() + document.blocks.length * 2;
    return math.max(2048.0, lines * lineHeight + 1024);
  }

  void _rebuildScrollSlices(NovelPaginationResult result) {
    final slices = <NovelScrollSlice>[];
    var top = 0.0;
    for (final page in result.pages) {
      var bottom = 0.0;
      for (final fragment in page.fragments) {
        bottom = math.max(bottom, fragment.offset.dy + fragment.height);
      }
      final height = bottom + _preferences.bottomMargin;
      slices.add(NovelScrollSlice(page: page, top: top, height: height));
      top += height;
    }
    _scrollSlices = List.unmodifiable(slices);
    _scrollContentHeight = top;
  }

  double? _scrollOffsetForLocator(NovelLocator? locator) {
    if (locator == null || _scrollSlices.isEmpty) return 0;
    final blockId = locator.blockId;
    if (blockId != null) {
      final offset = locator.charOffset ?? 0;
      for (final slice in _scrollSlices) {
        for (final fragment in slice.page.fragments) {
          if (fragment.blockId != blockId) continue;
          if (offset >= fragment.sourceStart && offset <= fragment.sourceEnd) {
            return slice.top + fragment.offset.dy - _preferences.topMargin;
          }
        }
      }
    }
    // 没有锚点(或锚点已失效)就按比例落位。真实可滚距离要等视图报上来,
    // 先用「内容高度」当上界,视图会再夹一次。
    return math.max(0, _scrollContentHeight * locator.fraction);
  }

  @override
  Future<void> loadChapter(
    String chapterId,
    NovelDocument document,
    NovelReaderPreferences preferences,
  ) async {
    _chapterId = chapterId;
    _preferences = preferences;
    await _syncBackground();
    _document = NovelRenderDocumentParser.parse(document);
    _locator = NovelLocator(chapterId: chapterId);
    _spreadIndex = 0;
    await _registerSelectedFont();
    _invalidateLayout();
    notifyListeners();
  }

  @override
  Future<NovelLocator> captureLocator() async {
    return _currentLocator() ?? NovelLocator(chapterId: _chapterId);
  }

  Future<void> _registerSelectedFont() async {
    final requested = _preferences.fontFamily;
    await _fontRegistry.register(requested);
    _fontLoadFailed = _fontRegistry.failed(requested);
  }

  @override
  Future<NovelPageMetrics> pageMetrics() async {
    final pagination = _pagination;
    if (pagination == null) {
      return NovelPageMetrics(
        pageCount: 1,
        currentPageIndex: 0,
        viewport: const NovelViewport(width: 0, height: 0),
        layoutFingerprint: '',
        fontLoadFailed: _fontLoadFailed,
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
      fontLoadFailed: _fontLoadFailed,
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
      if (isScrollMode) {
        _pendingScrollOffset = _scrollOffsetForLocator(locator);
        _scrollOffset = _pendingScrollOffset ?? 0;
      } else {
        _spreadIndex = _spreadForLocator(pagination, locator);
      }
    }
    notifyListeners();
  }

  @override
  Future<void> applyPreferences(NovelReaderPreferences preferences) async {
    _locator = _currentLocator();
    final previousLayout = _preferenceLayoutSignature(_preferences);
    final previousFamily = _fontRegistry.familyFor(_preferences.fontFamily);
    _preferences = preferences;
    // 导入字体要先真正注册进引擎才能拿来排版 —— 而且必须在这里等它,阅读页紧接着
    // 就要读 pageMetrics().fontLoadFailed 决定是不是回退。
    await _registerSelectedFont();
    // 背景只影响绘制,不影响断行,所以它换了也走下面的「丢页帧、不重排」这条路。
    await _syncBackground();
    if (_fontRegistry.familyFor(preferences.fontFamily) != previousFamily) {
      _invalidateLayout();
      notifyListeners();
      return;
    }
    if (_preferenceLayoutSignature(preferences) == previousLayout) {
      // 只改了颜色 / 背景 / 亮度:断行没变,重排整章纯属浪费,丢掉页帧重画即可。
      _clearRasterCache();
    } else {
      _invalidateLayout();
    }
    notifyListeners();
  }

  /// 把设置里选的背景解码成一张可直接上画布的图。
  ///
  /// 换不动就不重新读盘；换了才重新解码，以免每改一次字号都去碰一次文件。
  Future<void> _syncBackground() async {
    final key = _preferences.backgroundAssetId ??
        (_preferences.theme == NovelReaderTheme.paper
            ? _paperBackgroundKey
            : null);
    if (key == _backgroundKey && (key == null || _backgroundImage != null)) {
      return;
    }
    _backgroundKey = key;
    final generation = ++_backgroundGeneration;
    _backgroundImage?.dispose();
    _backgroundImage = null;
    if (key == null) return;
    ui.Image? image;
    try {
      final record = key == _paperBackgroundKey
          ? await _backgroundStore.paperTexture(seed: novelPaperTextureSeed)
          : await _backgroundStore.resolve(key);
      if (record != null) {
        image = await decodeImageFromList(await record.file.readAsBytes());
      }
    } catch (_) {
      image = null;
    }
    if (generation != _backgroundGeneration) {
      image?.dispose();
      return;
    }
    if (image == null) {
      // 图没了或者解不开：回到主题底色，并告诉阅读页把这项设置清掉 ——
      // 否则读者永远在设置面里看到一个早就失效的背景。
      _backgroundKey = null;
      if (key != _paperBackgroundKey) onBackgroundFallback?.call();
      return;
    }
    _backgroundImage = image;
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
    if (isScrollMode) return _currentScrollLocator();
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

  NovelLocator _currentScrollLocator() {
    final anchor = _scrollOffset + _preferences.topMargin;
    for (final slice in _scrollSlices) {
      if (anchor > slice.top + slice.height) continue;
      for (final fragment in slice.page.fragments) {
        if (fragment.sourceText.isEmpty) continue;
        if (slice.top + fragment.offset.dy + fragment.height >= anchor) {
          return NovelLocator(
            chapterId: _chapterId,
            blockId: fragment.blockId,
            charOffset: fragment.sourceStart,
            fraction: _scrollFraction,
          );
        }
      }
    }
    return NovelLocator(chapterId: _chapterId, fraction: _scrollFraction);
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
    // 上一轮的信号已经兑现过了，下一个等待者得拿到新的。
    if (_paginationWaiter?.isCompleted ?? false) _paginationWaiter = null;
  }

  /// 页帧缓存的 key。
  ///
  /// 排版指纹只描述「字断在哪里」，换主题、换背景、拉亮度都不会动它 —— 于是
  /// `NovelPageCache.invalidateLayout` 认不出旧页帧，换了夜间模式还在用白天配色的
  /// 位图。所以帧 key = 排版指纹 + 像素密度 + 所有只影响像素的设置。
  String _rasterFingerprint(NovelPaginationResult pagination) =>
      '${pagination.layoutFingerprint}'
      '@${_rasterDevicePixelRatio.toStringAsFixed(2)}'
      '@${_preferencePaintSignature(_preferences)}';

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

    // 一次栅格化用一只临时缓存,画完立刻释放 —— 这些 TextPainter 只服务这一帧。
    final textCache = NovelPageTextCache();

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
        background: pageBackground,
        textCache: textCache,
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
    // 亮度遮罩盖整张画布，页帧才能和实时渲染长得一样。
    final mask = novelReaderBrightnessMask(_preferences.brightness);
    if (mask != null) {
      canvas.drawRect(
        Offset.zero & pagination.viewport,
        Paint()..color = mask,
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
      textCache.dispose();
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
    _disposed = true;
    _backgroundGeneration++;
    _backgroundImage?.dispose();
    _backgroundImage = null;
    _clearRasterCache();
    // 别把等排版的人挂在那里。
    final waiter = _paginationWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    scrollController.dispose();
    super.dispose();
  }
}

class NovelScrollSlice {
  const NovelScrollSlice({
    required this.page,
    required this.top,
    required this.height,
  });

  final NovelPageLayout page;
  final double top;
  final double height;
}

class NovelNativeDocumentView extends StatelessWidget {
  const NovelNativeDocumentView({
    super.key,
    required this.controller,
    this.onReachedEnd,
  });

  final NovelNativeDocumentController controller;

  /// 滚动模式滚到本章尽头还继续拉时触发,由阅读页负责翻章。
  final ValueChanged<NovelTurnDirection>? onReachedEnd;

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
            if (controller.isScrollMode) {
              return NovelNativeScrollView(
                controller: controller,
                pagination: pagination,
                canvasColor: canvasColor,
                pageColor: pageColor,
                textColor: Color(profile.foregroundArgb),
                background: controller.pageBackground,
                brightness: controller.preferences.brightness,
                onReachedEnd: onReachedEnd,
              );
            }
            return NovelNativePageView(
              pagination: pagination,
              spreadIndex: controller.spreadIndex,
              canvasColor: canvasColor,
              pageColor: pageColor,
              textColor: Color(profile.foregroundArgb),
              showPageNumbers: controller.preferences.showPageNumber,
              background: controller.pageBackground,
              brightness: controller.preferences.brightness,
            );
          },
        );
      },
    );
  }
}

/// 影响**断行**的设置。变了就必须重排整章。
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
      // 滚动模式用的是「整章一页」的版心,和分页排版结果完全不同 —— 切模式必须重排。
      value.turnMode == NovelPageTurnMode.scroll ? 'scroll' : 'paged',
    ].join('|');

/// 只影响**像素**的设置。变了不用重排,但已经栅格化的页帧全部作废。
String _preferencePaintSignature(NovelReaderPreferences value) => [
      value.theme.name,
      value.foregroundArgb,
      value.backgroundAssetId ?? '',
      value.backgroundFit.name,
      value.textureStrength.toStringAsFixed(3),
      value.brightness.toStringAsFixed(3),
      value.showPageNumber,
    ].join('|');

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
