import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../app/download_store.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';

/// 沉浸式阅读器:翻页(paged)/ 条漫竖读(webtoon)两种模式 + 半透明控制层。
///
/// - 图片走磁盘缓存(带 Referer),并**预加载后续 N 页**(设置里可调)。
/// - **无缝连读**:读到本章末尾自动加载并接上下一章(章节列表升序),不打断阅读。
/// - 翻页实时保存阅读进度,可从上次位置续读。
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.source,
    required this.manga,
    required this.chapters, // 完整章节表(升序:第1话在前)
    required this.index, // 起始章节在 chapters 中的下标
    this.imageHeaders = const {},
    this.initialPage = 0,
    this.onDebugFlat,
  });

  final MangaSource source;
  final Manga manga;
  final List<Chapter> chapters;
  final int index;
  final Map<String, String> imageHeaders;
  final int initialPage;

  /// 测试钩子:每次重建扁平列表时回传(已加载章节数, 扁平总页数)。
  @visibleForTesting
  final void Function(int loadedChapters, int flatPages)? onDebugFlat;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

/// 已加载的一章。
class _Seg {
  _Seg(this.chapterIndex, this.chapter, this.pages);
  final int chapterIndex;
  final Chapter chapter;
  final List<PageImage> pages;
}

/// 扁平化后的一页(跨章连续)。
class _FlatPage {
  _FlatPage(this.img, this.chapter, this.chapterIndex, this.localPage,
      this.localTotal, this.chapterStartFlat);
  final PageImage img;
  final Chapter chapter;
  final int chapterIndex;
  final int localPage; // 章内页码(0 基)
  final int localTotal;
  final int chapterStartFlat; // 本章在扁平列表里的起始下标
}

class _ReaderPageState extends State<ReaderPage> {
  late final PageController _ctrl =
      PageController(initialPage: widget.initialPage);
  final ItemScrollController _itemCtrl = ItemScrollController();
  final ItemPositionsListener _itemPos = ItemPositionsListener.create();

  LibraryStore? _store;
  DownloadStore? _downloads;
  ReaderMode _mode = ReaderMode.paged;
  bool _dual = false; // 双页同看(仅翻页模式)
  bool _dtZoom = true; // 允许双击缩放
  bool _showPageNum = true; // 展示页码
  double _brightness = 1.0; // 亮度(遮罩)

  final List<_Seg> _segments = [];
  List<_FlatPage> _flat = [];
  int _curFlat = 0;
  bool _loadingNext = false;
  bool _reachedEnd = false;
  String? _error;
  bool _overlay = true;
  bool _showHint = false; // 首次进入的手势提示遮罩

  @override
  void initState() {
    super.initState();
    _curFlat = widget.initialPage;
    _itemPos.itemPositions.addListener(_onWebtoonScroll);
    // 只读(非依赖)scope,initState 里就安全可读;必须在 _loadInitial 之前赋值,
    // 否则首章的 _fetch 同步前缀读到的 _downloads 为 null,会绕过已下载的本地文件、
    // 强走网络(离线时首章加载失败)。
    _store = LibraryScope.read(context);
    _downloads = DownloadScope.maybeRead(context);
    final s = _store!;
    _mode = s.readerMode;
    _dual = s.doublePage;
    _dtZoom = s.doubleTapZoom;
    _showPageNum = s.showPageNumber;
    _brightness = s.brightness;
    _loadInitial();
  }

  bool get _isPaged => _mode != ReaderMode.webtoon;
  bool get _rtl => _mode == ReaderMode.pagedRtl;
  bool get _dualActive => _dual && _isPaged;
  int _pageForFlat(int flat) => _dualActive ? flat ~/ 2 : flat;
  int _flatForPage(int page) => _dualActive ? page * 2 : page;

  Chapter get _startChapter => widget.chapters[widget.index];

  Future<List<PageImage>> _fetch(int chapterIndex) async {
    final ch = widget.chapters[chapterIndex];
    // 已下载:直接读本地文件(离线可用,url 存本地路径)。
    final local =
        _downloads?.localPages(widget.source.id, widget.manga.id, ch.id);
    if (local != null && local.isNotEmpty) {
      return [for (var i = 0; i < local.length; i++) PageImage(index: i, url: local[i])];
    }
    return widget.source.getPages(widget.manga.id, ch.id);
  }

  Future<void> _loadInitial() async {
    try {
      final pages = await _fetch(widget.index);
      if (!mounted) return;
      if (pages.isEmpty) {
        // 空章节 —— 退回并提示(延到帧后,getPages 可能极快返回时树处于锁定期)。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('本章暂无图片,已返回')),
          );
          Navigator.of(context).maybePop();
        });
        return;
      }
      _segments.add(_Seg(widget.index, _startChapter, pages));
      _rebuildFlat();
      // 首次进入 + 开着手势 → 显示一次分区手势提示。
      final s = _store;
      final showHint =
          s != null && !s.readerGestureHintSeen && s.readerGestures;
      if (showHint) s.readerGestureHintSeen = true;
      setState(() {
        _curFlat = _curFlat.clamp(0, _flat.length - 1);
        if (showHint) _showHint = true;
      });
      _saveProgress();
      _preload();
      _maybeLoadNext(); // 若起始就接近末尾(短章/续读到尾),提前接上下一章
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _rebuildFlat() {
    final flat = <_FlatPage>[];
    var offset = 0;
    for (final seg in _segments) {
      final total = seg.pages.length;
      for (var i = 0; i < total; i++) {
        flat.add(_FlatPage(
            seg.pages[i], seg.chapter, seg.chapterIndex, i, total, offset));
      }
      offset += total;
    }
    _flat = flat;
    widget.onDebugFlat?.call(_segments.length, _flat.length);
  }

  // 读到接近末尾时,自动加载并接上下一章。
  Future<void> _maybeLoadNext() async {
    if (_loadingNext || _reachedEnd || _flat.isEmpty) return;
    if (_curFlat < _flat.length - 3) return; // 还没接近末尾
    final nextIndex = _segments.last.chapterIndex + 1;
    if (nextIndex >= widget.chapters.length) {
      _reachedEnd = true;
      return;
    }
    _loadingNext = true;
    try {
      final pages = await _fetch(nextIndex);
      if (!mounted) return;
      if (pages.isEmpty) {
        _reachedEnd = true; // 下一章暂无图片,停止自动接续
        return;
      }
      _segments.add(_Seg(nextIndex, widget.chapters[nextIndex], pages));
      _rebuildFlat();
      setState(() {});
      _preload();
    } catch (_) {
      // 加载失败不致命:下次滚动/翻页再试。
    } finally {
      _loadingNext = false;
    }
  }

  Map<String, String> _headers(PageImage img) =>
      {...widget.imageHeaders, ...?img.headers};

  ImageProvider _providerFor(PageImage img) => img.url.startsWith('http')
      ? CachedNetworkImageProvider(img.url,
          cacheManager: appImageCache, headers: _headers(img))
      : FileImage(File(img.url));

  void _preload() {
    final n = _store?.preload ?? 0;
    if (n <= 0 || _flat.isEmpty || !mounted) return;
    final end = (_curFlat + n).clamp(0, _flat.length - 1);
    // 近处几页**解码到内存**(precacheImage),翻到时零加载、无 % 占位;
    // 更远的只**下到磁盘**(省内存,翻到时最多一次解码)。
    // 双页模式一次跨两页,多解一页盖住下一对开页。
    final decodeAhead = _dualActive ? 4 : 3;
    for (var j = _curFlat + 1; j <= end; j++) {
      final img = _flat[j].img;
      if (j - _curFlat <= decodeAhead) {
        precacheImage(_providerFor(img), context, onError: (_, __) {});
      } else if (img.url.startsWith('http')) {
        unawaited(appImageCache
            .getSingleFile(img.url, headers: _headers(img))
            .then((_) {}, onError: (_) {}));
      }
    }
  }

  void _saveProgress() {
    if (_flat.isEmpty || _store == null) return;
    final fp = _flat[_curFlat.clamp(0, _flat.length - 1)];
    _store!.markProgress(
      sourceId: widget.source.id,
      mangaId: widget.manga.id,
      title: widget.manga.title,
      cover: widget.manga.cover,
      chapterId: fp.chapter.id,
      chapterName: fp.chapter.name,
      page: fp.localPage,
      total: fp.localTotal,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _onFlatChanged(int i) {
    if (i == _curFlat || i < 0 || i >= _flat.length) return;
    setState(() => _curFlat = i);
    _saveProgress();
    _preload();
    _maybeLoadNext();
  }

  void _onWebtoonScroll() {
    if (_mode != ReaderMode.webtoon || _flat.isEmpty) return;
    final positions = _itemPos.itemPositions.value;
    if (positions.isEmpty) return;
    int? top;
    for (final p in positions) {
      if (p.itemTrailingEdge > 0 && (top == null || p.index < top)) {
        top = p.index;
      }
    }
    if (top != null) _onFlatChanged(top);
  }

  void _switchMode(ReaderMode m) {
    if (m == _mode) return;
    setState(() => _mode = m);
    _store?.readerMode = m;
    _resyncPaged();
  }

  void _setDual(bool v) {
    if (v == _dual) return;
    setState(() => _dual = v);
    _store?.doublePage = v;
    _resyncPaged();
  }

  // 模式/双页变化后,把翻页控制器重新对到当前页(itemCount 可能变了)。
  void _resyncPaged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isPaged && _ctrl.hasClients) _ctrl.jumpToPage(_pageForFlat(_curFlat));
    });
  }

  void _jumpTo(int flatIndex) {
    final i = flatIndex.clamp(0, _flat.length - 1);
    if (_mode == ReaderMode.webtoon) {
      if (_itemCtrl.isAttached) _itemCtrl.jumpTo(index: i);
    } else if (_ctrl.hasClients) {
      _ctrl.jumpToPage(_pageForFlat(i));
    }
    _onFlatChanged(i);
  }

  bool get _hasPrevChapter => _flat.isNotEmpty && _cur.chapterIndex > 0;
  bool get _hasNextChapter =>
      _flat.isNotEmpty && _cur.chapterIndex < widget.chapters.length - 1;

  void _jumpChapter(int delta) {
    if (_flat.isEmpty) return;
    final target = _cur.chapterIndex + delta;
    if (target < 0 || target >= widget.chapters.length) return;
    // 已加载(通常是后续章)→ 直接跳到该章首页,保持无缝滚动体验。
    var start = 0;
    var found = false;
    for (final s in _segments) {
      if (s.chapterIndex == target) {
        found = true;
        break;
      }
      start += s.pages.length;
    }
    if (found) {
      _jumpTo(start);
      return;
    }
    // 未加载(通常是上一章)→ 以目标章为起点重开阅读器。
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ReaderPage(
        source: widget.source,
        manga: widget.manga,
        chapters: widget.chapters,
        index: target,
        imageHeaders: widget.imageHeaders,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final landscape = size.width > size.height; // 横屏
    return Scaffold(
      // 「阅读器显示背景」开启 → 透明,露出全局背景;否则用近黑纯色。
      backgroundColor: (_store?.readerBackground ?? false)
          ? Colors.transparent
          : const Color(0xFF050807),
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey, // 键盘快捷键(方向键/空格/PageUp·Down 翻页,Esc 退出)
        child: Listener(
          onPointerSignal: _onWheel, // 翻页模式滚轮翻页(条漫让列表自己滚)
          child: Stack(
            children: [
              // 图片/列表排出无障碍树:漫画页无需 a11y,且大量图片加载会让 Windows
              // 无障碍桥(AXTree)持续报错刷屏、卡到退不出页面。控制条仍保留语义。
              ExcludeSemantics(child: _content()),
              // 亮度遮罩(在内容之上、控制条之下,不拦手势)。
              if (_brightness < 1.0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                        color:
                            Colors.black.withValues(alpha: 1 - _brightness)),
                  ),
                ),
              if (_flat.isNotEmpty) ...[
                if (_showPageNum && !_overlay) _pageIndicator(),
                // 横屏:进度条竖排到左侧;竖屏:横排在底部。
                landscape ? _sideBar() : _bottomBar(),
                _topBar(), // 放最上层:返回键不被左侧竖排进度条盖住
              ] else
                _fallbackBack(),
              if (_showHint) _gestureHint(),
            ],
          ),
        ),
      ),
    );
  }

  /// 首次进入(或设置里手动调出)的分区手势提示遮罩:可视化左/中/右点击区。
  Widget _gestureHint() {
    final rtl = _rtl;
    final webtoon = _mode == ReaderMode.webtoon;
    // 手势关掉时(仍可从设置里手动调出提示)只展示中间切控制条,不误导有翻页分区。
    final gesturesOff = !(_store?.readerGestures ?? true);

    Widget zone(int flex, IconData icon, String label, double bgAlpha) =>
        Expanded(
          flex: flex,
          child: Container(
            color: Colors.white.withValues(alpha: bgAlpha),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 40),
                const SizedBox(height: 10),
                Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        );

    final Widget zones = webtoon
        ? zone(1, Icons.swap_vert_rounded, '上下滑动翻页\n点击切换控制条', 0.05)
        : gesturesOff
            ? zone(1, Icons.touch_app_rounded, '点击切换控制条\n(翻页手势已关)', 0.05)
            : Row(children: [
                zone(
                    30,
                    rtl
                        ? Icons.chevron_right_rounded
                        : Icons.chevron_left_rounded,
                    rtl ? '下一页' : '上一页',
                    0.10),
                zone(40, Icons.touch_app_rounded, '控制条', 0.03),
                zone(
                    30,
                    rtl
                        ? Icons.chevron_left_rounded
                        : Icons.chevron_right_rounded,
                    rtl ? '上一页' : '下一页',
                    0.10),
              ]);

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showHint = false),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: LibraryStore.animationsEnabled
              ? const Duration(milliseconds: 260)
              : Duration.zero,
          curve: Curves.easeOut,
          builder: (_, v, child) => Opacity(opacity: v, child: child),
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.62),
            child: Stack(
              children: [
                Positioned.fill(child: zones),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 46,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.gesture_rounded,
                          color: Colors.white70, size: 22),
                      const SizedBox(height: 8),
                      Text('点击任意处关闭 · 可在阅读设置里开关手势',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.75),
                              fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 翻一页(dir=±1)。双页模式一次跨两页。开动画时用 animateToPage 播翻页效果。
  void _turn(int dir) {
    if (_flat.isEmpty) return;
    final step = _dualActive ? 2 : 1;
    final target = (_curFlat + dir * step).clamp(0, _flat.length - 1);
    if (target == _curFlat) return;
    if (_mode != ReaderMode.webtoon &&
        _ctrl.hasClients &&
        LibraryStore.animationsEnabled) {
      _ctrl.animateToPage(_pageForFlat(target),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic);
      _onFlatChanged(target); // 立即更新状态;settle 时同值被 guard,不重复
    } else {
      _jumpTo(target);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.pageDown) {
      _turn(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.pageUp) {
      _turn(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  DateTime _lastWheel = DateTime.fromMillisecondsSinceEpoch(0);
  void _onWheel(PointerSignalEvent event) {
    if (_mode == ReaderMode.webtoon) return; // 条漫:让 SPL 自己滚
    if (event is PointerScrollEvent) {
      final now = DateTime.now();
      if (now.difference(_lastWheel).inMilliseconds < 120) return; // 防一滚翻多页
      _lastWheel = now;
      _turn(event.scrollDelta.dy > 0 ? 1 : -1);
    }
  }

  // 常驻小页码(控制条收起时显示)。
  Widget _pageIndicator() {
    final fp = _cur;
    return Positioned(
      bottom: 10,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('${fp.localPage + 1} / ${fp.localTotal}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ),
      ),
    );
  }

  Widget _content() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.white54, size: 40),
              const SizedBox(height: 12),
              SelectableText('加载失败:\n$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      );
    }
    if (_flat.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, cons) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _onTapUp(d.localPosition.dx, cons.maxWidth),
        child: _mode == ReaderMode.webtoon ? _webtoon() : _paged(),
      ),
    );
  }

  /// 点击分区:两侧翻页、中间切控制条。日漫(RTL)左右镜像(左=下一页,符合右起阅读)。
  void _onTapUp(double x, double width) {
    // 手势关掉 / 条漫:任意点击只切控制条(不翻页)。
    if (!(_store?.readerGestures ?? true) ||
        _mode == ReaderMode.webtoon ||
        width <= 0) {
      setState(() => _overlay = !_overlay);
      return;
    }
    final left = width * 0.30;
    final right = width * 0.70;
    if (x < left) {
      _turn(_rtl ? 1 : -1); // 左侧:普通=上一页 / 日漫=下一页
    } else if (x > right) {
      _turn(_rtl ? -1 : 1); // 右侧:普通=下一页 / 日漫=上一页
    } else {
      setState(() => _overlay = !_overlay); // 中间:切控制条
    }
  }

  Widget _paged() {
    final count = _dualActive ? (_flat.length + 1) ~/ 2 : _flat.length;
    // 日漫模式 + 开动画:给每页加「书页翻折」效果(绕书脊透视折叠 + 边缘阴影)。
    final turn = _rtl && LibraryStore.animationsEnabled;
    return ScrollConfiguration(
      // 桌面也允许鼠标拖动滑页(默认只认触摸/触控板);触摸端本就能滑。
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: PageView.builder(
        controller: _ctrl,
        reverse: _rtl, // 日漫:右→左翻
        // 预加载开启时提前**建好相邻页的 UI**(配合图片解码预载 → 翻页零加载)。
        allowImplicitScrolling: (_store?.preload ?? 0) > 0,
        itemCount: count,
        onPageChanged: (p) => _onFlatChanged(_flatForPage(p)),
        itemBuilder: (_, p) => _PageTurn(
          controller: _ctrl,
          index: p,
          enabled: turn,
          child: _zoomable(_pagedItem(p)),
        ),
      ),
    );
  }

  Widget _pagedItem(int p) {
    if (!_dualActive) return Center(child: _image(_flat[p].img, BoxFit.contain));
    // 双页并排:靠中缝对齐,阅读顺序 LTR 左=靠前页,RTL 右=靠前页。
    final firstImg = _flat[2 * p].img;
    final secondImg =
        (2 * p + 1) < _flat.length ? _flat[2 * p + 1].img : null;
    final left = _rtl ? secondImg : firstImg;
    final right = _rtl ? firstImg : secondImg;
    return Row(
      children: [
        _half(left, Alignment.centerRight),
        _half(right, Alignment.centerLeft),
      ],
    );
  }

  Widget _half(PageImage? img, Alignment align) => Expanded(
        child: img == null
            ? const SizedBox()
            : Align(alignment: align, child: _image(img, BoxFit.contain)),
      );

  // 缩放:双指恒可缩放;双击缩放按设置开关。
  Widget _zoomable(Widget child) =>
      _ZoomableView(doubleTap: _dtZoom, child: child);

  Widget _webtoon() {
    final size = MediaQuery.of(context).size;
    final landscape = size.width > size.height;
    // 横屏:内容列宽 = 屏宽 × 占比(阅读设置可调,越窄图越小=一屏看得更长);
    // 竖屏本就窄,用满宽。
    final maxW =
        landscape ? size.width * (_store?.webtoonWidth ?? 0.5) : size.width;
    return ScrollablePositionedList.builder(
      itemScrollController: _itemCtrl,
      itemPositionsListener: _itemPos,
      initialScrollIndex: _curFlat.clamp(0, _flat.length - 1),
      itemCount: _flat.length,
      itemBuilder: (_, i) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: _image(_flat[i].img, BoxFit.fitWidth, fullWidth: true),
        ),
      ),
    );
  }

  Widget _image(PageImage img, BoxFit fit, {bool fullWidth = false}) {
    // 本地下载的页:直接读文件(url 非 http)。
    if (!img.url.startsWith('http')) {
      return Image.file(
        File(img.url),
        fit: fit,
        width: fullWidth ? double.infinity : null,
        errorBuilder: (_, __, ___) => _broken(fullWidth),
      );
    }
    return CachedNetworkImage(
      cacheManager: appImageCache,
      imageUrl: img.url,
      httpHeaders: _headers(img),
      fit: fit,
      width: fullWidth ? double.infinity : null,
      fadeInDuration: const Duration(milliseconds: 120),
      progressIndicatorBuilder: (ctx, url, p) => _loading(p, fullWidth),
      errorWidget: (_, __, ___) => _broken(fullWidth),
    );
  }

  Widget _broken(bool fullWidth) => Container(
        height: fullWidth ? 200 : null,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_rounded,
            color: Colors.white38, size: 40),
      );

  // 加载占位:无背景,仅居中显示加载百分比(占位高度保留,避免布局跳动)。
  Widget _loading(DownloadProgress p, bool fullWidth) {
    final prog = p.progress;
    final label = prog != null ? '${(prog * 100).round()}%' : '…';
    return SizedBox(
      width: fullWidth ? double.infinity : 300,
      height: 440,
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  Widget _fallbackBack() => Positioned(
        top: 0,
        left: 0,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 28, left: 4),
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white70),
            ),
          ),
        ),
      );

  _FlatPage get _cur => _flat[_curFlat.clamp(0, _flat.length - 1)];

  Widget _topBar() => AnimatedPositioned(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        left: 0,
        right: 0,
        top: _overlay ? 0 : -140,
        child: AnimatedOpacity(
          opacity: _overlay ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Container(
          padding: const EdgeInsets.fromLTRB(8, 36, 8, 20),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(widget.manga.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 14)),
                    Text(_cur.chapter.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 11)),
                  ],
                ),
              ),
              IconButton(
                onPressed: _openSettings,
                icon: const Icon(Icons.tune_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
        ),
      );

  Widget _chapBtn(IconData icon, VoidCallback? onTap) => IconButton(
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
        icon: Icon(icon,
            color: onTap != null ? Colors.white : Colors.white24, size: 22),
      );

  Widget _bottomBar() {
    final fp = _cur;
    final total = fp.localTotal;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: 0,
      right: 0,
      bottom: _overlay ? 0 : -120,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 26),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            _chapBtn(Icons.skip_previous_rounded,
                _hasPrevChapter ? () => _jumpChapter(-1) : null),
            Text('${fp.localPage + 1}',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()])),
            Expanded(
              child: Slider(
                value: fp.localPage.toDouble().clamp(0, (total - 1).toDouble()),
                min: 0,
                max: (total - 1).toDouble().clamp(0, double.infinity),
                onChanged: total > 1
                    ? (v) => _jumpTo(fp.chapterStartFlat + v.round())
                    : null,
              ),
            ),
            Text('$total',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()])),
            _chapBtn(Icons.skip_next_rounded,
                _hasNextChapter ? () => _jumpChapter(1) : null),
          ],
        ),
      ),
    );
  }

  // 横屏:左侧竖排进度条(计数 + 竖向 slider)。
  Widget _sideBar() {
    final fp = _cur;
    final total = fp.localTotal;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      top: 0,
      bottom: 0,
      left: _overlay ? 0 : -90,
      child: Container(
        width: 66,
        padding: const EdgeInsets.fromLTRB(6, 96, 6, 28),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          children: [
            _chapBtn(Icons.skip_previous_rounded,
                _hasPrevChapter ? () => _jumpChapter(-1) : null),
            Text('${fp.localPage + 1}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()])),
            Expanded(
              // 旋转的可交互控件在 Windows 无障碍桥上会触发 AXTree 崩溃,排出语义树。
              child: ExcludeSemantics(
                child: RotatedBox(
                  quarterTurns: 1, // 竖向:第1页在上
                  child: Slider(
                    value: fp.localPage
                        .toDouble()
                        .clamp(0, (total - 1).toDouble()),
                    min: 0,
                    max: (total - 1).toDouble().clamp(0, double.infinity),
                    onChanged: total > 1
                        ? (v) => _jumpTo(fp.chapterStartFlat + v.round())
                        : null,
                  ),
                ),
              ),
            ),
            Text('$total',
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontFeatures: [FontFeature.tabularFigures()])),
            _chapBtn(Icons.skip_next_rounded,
                _hasNextChapter ? () => _jumpChapter(1) : null),
          ],
        ),
      ),
    );
  }

  // 阅读设置面板(参考主流阅读器)。
  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final p = ctx.palette;
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            void apply(VoidCallback f) {
              f();
              setSheet(() {});
            }

            TextStyle t(Color c, [double s = 13.5]) => TextStyle(
                color: c, fontSize: s, fontWeight: FontWeight.w600);
            return SafeArea(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    Text('阅读设置',
                        style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 14),
                    Text('阅读模式',
                        style: TextStyle(color: p.textMuted, fontSize: 12)),
                    const SizedBox(height: 8),
                    SegmentedButton<ReaderMode>(
                      segments: const [
                        ButtonSegment(
                            value: ReaderMode.paged,
                            label: Text('普通'),
                            icon: Icon(Icons.arrow_forward_rounded, size: 15)),
                        ButtonSegment(
                            value: ReaderMode.pagedRtl,
                            label: Text('日漫'),
                            icon: Icon(Icons.arrow_back_rounded, size: 15)),
                        ButtonSegment(
                            value: ReaderMode.webtoon,
                            label: Text('滚动'),
                            icon: Icon(Icons.arrow_downward_rounded, size: 15)),
                      ],
                      selected: {_mode},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) =>
                          apply(() => _switchMode(s.first)),
                    ),
                    if (_mode == ReaderMode.webtoon) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.aspect_ratio_rounded,
                              size: 18, color: p.textMuted),
                          const SizedBox(width: 8),
                          Text('横屏内容宽度', style: t(p.textPrimary)),
                          Expanded(
                            child: Slider(
                              value:
                                  (_store?.webtoonWidth ?? 0.5).clamp(0.3, 1.0),
                              min: 0.3,
                              max: 1.0,
                              divisions: 14,
                              label:
                                  '${((_store?.webtoonWidth ?? 0.5) * 100).round()}%',
                              onChanged: (v) => apply(() {
                                _store?.webtoonWidth = v;
                                setState(() {}); // 阅读器按新宽度即时重建
                              }),
                            ),
                          ),
                          SizedBox(
                            width: 42,
                            child: Text(
                                '${((_store?.webtoonWidth ?? 0.5) * 100).round()}%',
                                textAlign: TextAlign.end,
                                style:
                                    TextStyle(color: p.textMuted, fontSize: 12)),
                          ),
                        ],
                      ),
                      Text('仅横屏生效 · 越窄一屏看得越长',
                          style: TextStyle(color: p.textMuted, fontSize: 11)),
                    ],
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('双页同看', style: t(p.textPrimary)),
                      subtitle: Text('翻页模式下并排显示两页',
                          style: TextStyle(color: p.textMuted, fontSize: 11)),
                      value: _dual,
                      onChanged:
                          _isPaged ? (v) => apply(() => _setDual(v)) : null,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('允许双击缩放', style: t(p.textPrimary)),
                      value: _dtZoom,
                      onChanged: (v) => apply(() {
                        setState(() => _dtZoom = v);
                        _store?.doubleTapZoom = v;
                      }),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('展示页码', style: t(p.textPrimary)),
                      value: _showPageNum,
                      onChanged: (v) => apply(() {
                        setState(() => _showPageNum = v);
                        _store?.showPageNumber = v;
                      }),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('点击分区翻页', style: t(p.textPrimary)),
                      subtitle: Text('屏幕左/右侧点击翻页,中间切控制条',
                          style: TextStyle(color: p.textMuted, fontSize: 11)),
                      value: _store?.readerGestures ?? true,
                      onChanged: (v) =>
                          apply(() => _store?.readerGestures = v),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          setState(() => _showHint = true);
                        },
                        icon: const Icon(Icons.gesture_rounded, size: 16),
                        label: const Text('查看手势提示'),
                        style: TextButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text('亮度',
                        style: TextStyle(color: p.textMuted, fontSize: 12)),
                    Row(
                      children: [
                        Icon(Icons.nightlight_round,
                            size: 18, color: p.textMuted),
                        Expanded(
                          child: Slider(
                            value: _brightness,
                            min: 0.25,
                            max: 1.0,
                            onChanged: (v) => apply(() {
                              setState(() => _brightness = v);
                              _store?.brightness = v;
                            }),
                          ),
                        ),
                        Icon(Icons.wb_sunny_rounded, size: 18, color: p.textMuted),
                      ],
                    ),
                  ],
                ),
              ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _itemPos.itemPositions.removeListener(_onWebtoonScroll);
    _ctrl.dispose();
    super.dispose();
  }
}

/// 可缩放视图:双指恒可缩放;双击缩放/复位按需开启。
/// 日漫翻页效果:随 PageView 滚动,把每页绕「书脊」做透视折叠 + 一道边缘阴影,
/// 读起来像翻纸。静止(t==0)时不套任何变换层(桌面性能 + 不影响缩放命中)。
class _PageTurn extends StatelessWidget {
  const _PageTurn({
    required this.controller,
    required this.index,
    required this.enabled,
    required this.child,
  });

  final PageController controller;
  final int index;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return AnimatedBuilder(
      animation: controller,
      // child 只建一次,不随每个 tick 重建(重活在这里,变换在 builder 里)。
      child: child,
      builder: (context, child) {
        var page = index.toDouble();
        if (controller.hasClients && controller.position.haveDimensions) {
          page = controller.page ?? page;
        }
        final t = (index - page).clamp(-1.0, 1.0);
        if (t == 0) return child!; // 静止:原样返回
        // 书脊:t>0(本页在滚动方向前侧)绕右缘折,t<0 绕左缘折。
        final foldRight = t > 0;
        final align = foldRight ? Alignment.centerRight : Alignment.centerLeft;
        final m = Matrix4.identity()
          ..setEntry(3, 2, 0.0013) // 透视
          ..rotateY(-t * 0.72); // 折叠角
        return Transform(
          alignment: align,
          transform: m,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              child!,
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: align,
                        end: foldRight
                            ? Alignment.centerLeft
                            : Alignment.centerRight,
                        colors: [
                          Colors.black.withValues(alpha: 0.5 * t.abs()),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.55],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ZoomableView extends StatefulWidget {
  const _ZoomableView({required this.child, this.doubleTap = true});
  final Widget child;
  final bool doubleTap;

  @override
  State<_ZoomableView> createState() => _ZoomableViewState();
}

class _ZoomableViewState extends State<_ZoomableView> {
  final TransformationController _tc = TransformationController();
  Offset _tapPos = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onXform);
  }

  // 是否已放大。未放大时不让 InteractiveViewer 吃横向拖动 → 交给外层 PageView 滑动翻页;
  // 放大后才允许拖动平移查看。
  void _onXform() {
    final z = _tc.value.getMaxScaleOnAxis() > 1.01;
    if (z != _zoomed) setState(() => _zoomed = z);
  }

  @override
  void dispose() {
    _tc.removeListener(_onXform);
    _tc.dispose();
    super.dispose();
  }

  void _onDoubleTap() {
    if (_tc.value != Matrix4.identity()) {
      _tc.value = Matrix4.identity(); // 已放大 → 复位
    } else {
      const s = 2.5;
      // 以双击点为中心放大:缩放置对角、平移置末列(-pos*(s-1) 使该点不动)。
      _tc.value = Matrix4.identity()
        ..setEntry(0, 0, s)
        ..setEntry(1, 1, s)
        ..setEntry(0, 3, -_tapPos.dx * (s - 1))
        ..setEntry(1, 3, -_tapPos.dy * (s - 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewer = InteractiveViewer(
      transformationController: _tc,
      maxScale: 5,
      panEnabled: _zoomed, // 未放大不吃横拖 → PageView 能滑动翻页
      child: widget.child,
    );
    if (!widget.doubleTap) return viewer;
    return GestureDetector(
      onDoubleTapDown: (d) => _tapPos = d.localPosition,
      onDoubleTap: _onDoubleTap,
      child: viewer,
    );
  }
}
