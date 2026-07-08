import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/download_store.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/net/image_cache.dart';
import '../../core/platform/reader_keys.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../ui/ui.dart';

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
  bool _pageZoomed = false; // 当前页是否放大(放大时禁用点击翻页,避免误翻)
  bool _wakeOn = false; // 本页是否已激活常亮(与 _wakeCount 配对)
  late final String _mangaKey; // 'sid:mid':每本漫画模式覆盖 / 自动判断的键
  final FocusNode _focus = FocusNode();

  // 常亮屏幕引用计数:章节跳转走 pushReplacement,新页 initState 先于旧页 dispose,
  // 计数确保中途不被旧页的 disable 关掉(仅最后一个阅读器退出才息屏)。
  static int _wakeCount = 0;
  // 沉浸系统栏 / 方向锁引用计数:章节跳转 pushReplacement 时新页 initState 先于旧页
  // dispose,仅最后一个阅读器退出才恢复系统栏 / 解方向锁(否则会清掉新页刚设的值)。
  static int _uiCount = 0;
  // 音量键翻页同样引用计数(章节跳转重叠期不被旧页关掉);_volKeyOn=本页是否已注册。
  static int _volKeyCount = 0;
  bool _volKeyOn = false;
  // 自动判断条漫的图片流监听:退出时若还没解出,主动摘掉(否则 State 被挂到未完成
  // 的图片请求上,慢网/挂起时长期不释放)。
  ImageStream? _detectStream;
  ImageStreamListener? _detectListener;

  @override
  void initState() {
    super.initState();
    _curFlat = widget.initialPage;
    _mangaKey = '${widget.source.id}:${widget.manga.id}';
    _itemPos.itemPositions.addListener(_onWebtoonScroll);
    // 只读(非依赖)scope,initState 里就安全可读;必须在 _loadInitial 之前赋值,
    // 否则首章的 _fetch 同步前缀读到的 _downloads 为 null,会绕过已下载的本地文件、
    // 强走网络(离线时首章加载失败)。
    _store = LibraryScope.read(context);
    _downloads = DownloadScope.maybeRead(context);
    final s = _store!;
    // 每本漫画的模式覆盖优先于全局默认;无覆盖时用全局默认。
    final savedMode = s.mangaMode(_mangaKey);
    _mode = savedMode != null
        ? ReaderMode.values
            .firstWhere((m) => m.name == savedMode, orElse: () => s.readerMode)
        : s.readerMode;
    _dual = s.doublePage;
    _dtZoom = s.doubleTapZoom;
    _showPageNum = s.showPageNumber;
    _brightness = s.brightness;
    _loadInitial();
    if (s.keepScreenOn) {
      _wakeOn = true;
      if (_wakeCount++ == 0) WakelockPlus.enable(); // 阅读时常亮(引用计数)
    }
    _uiCount++;
    _applySystemUi();
    _applyOrientation();
    if (s.volumeKeyPaging) _enableVolumeKeys();
  }

  bool get _isPaged => _mode != ReaderMode.webtoon;
  bool get _rtl => _mode == ReaderMode.pagedRtl;
  // 双页仅横向翻页(普通/日漫);竖翻、条漫不并排双页。
  bool get _dualActive =>
      _dual && (_mode == ReaderMode.paged || _mode == ReaderMode.pagedRtl);
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
          showAppNotify(context, '本章暂无图片,已返回', kind: AppNotifyKind.info);
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
      _maybeAutoDetect(); // 首次打开:高瘦条漫图自动切滚动模式
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
    final prevCh = _flat[_curFlat.clamp(0, _flat.length - 1)].chapterIndex;
    setState(() {
      _curFlat = i;
      _pageZoomed = false; // 翻页即退出放大禁翻态(离开的页也会复位缩放)
    });
    // 连读跨入新章:提示章节名(避免在帧内插 overlay,延到帧后)。
    if ((_store?.chapterToast ?? true) && _flat[i].chapterIndex != prevCh) {
      final name = _flat[i].chapter.name;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showAppNotify(context, name, kind: AppNotifyKind.info);
      });
    }
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
    // 切模式会换 _pageKey → 当前页元素被替换,旧 _ZoomableView 不发缩放回调;
    // 显式清掉禁翻标记,避免切换后点击翻页失灵。
    setState(() {
      _mode = m;
      _pageZoomed = false;
    });
    _store?.setMangaMode(_mangaKey, m); // 记住本漫画的选择
    _store?.readerMode = m; // 同时更新全局默认(新漫画沿用最近偏好)
    _resyncPaged();
  }

  void _setDual(bool v) {
    if (v == _dual) return;
    setState(() {
      _dual = v;
      _pageZoomed = false;
    });
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
          : _bgColor(),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey, // 键盘快捷键(方向键/空格/PageUp·Down 翻页,Esc 退出)
        child: Listener(
          onPointerSignal: _onWheel, // 翻页模式滚轮翻页(条漫让列表自己滚)
          child: Stack(
            children: [
              // 图片/列表排出无障碍树:漫画页无需 a11y,且大量图片加载会让 Windows
              // 无障碍桥(AXTree)持续报错刷屏、卡到退不出页面。控制条仍保留语义。
              // 色彩滤镜(黑白/反色/护眼/对比度)整层套一次,覆盖翻页 + 条漫。
              ExcludeSemantics(child: _filtered(_content())),
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

    final Widget zones = (webtoon || _mode == ReaderMode.vertical)
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
    // 阅读顺序(与 RTL 无关):下 / 空格 / PageDown = 下一页,上 / PageUp = 上一页。
    if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.pageDown) {
      _turn(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.pageUp) {
      _turn(-1);
      return KeyEventResult.handled;
    }
    // 左右方向键:按屏幕方向(日漫 RTL 镜像),与点击分区一致。
    if (k == LogicalKeyboardKey.arrowRight) {
      _turn(_rtl ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _turn(_rtl ? 1 : -1);
      return KeyEventResult.handled;
    }
    // 章节:N 下一章 / P 上一章。
    if (k == LogicalKeyboardKey.keyN) {
      if (_hasNextChapter) _jumpChapter(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyP) {
      if (_hasPrevChapter) _jumpChapter(-1);
      return KeyEventResult.handled;
    }
    // 本章首 / 末页。
    if (k == LogicalKeyboardKey.home) {
      _jumpTo(_cur.chapterStartFlat);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.end) {
      _jumpTo(_cur.chapterStartFlat + _cur.localTotal - 1);
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
    // 条漫 / 竖翻:纵向 Scrollable 自己吃滚轮,别再 _turn(否则和原生滚动打架)。
    if (_mode == ReaderMode.webtoon || _mode == ReaderMode.vertical) return;
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
      return AppErrorView(onDark: true, message: _error!);
    }
    if (_flat.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, cons) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _onTapUp(d.localPosition.dx, cons.maxWidth),
        onLongPress: _openSettings, // 长按调出阅读设置(Kotatsu 式菜单入口)
        child: _mode == ReaderMode.webtoon ? _webtoon() : _paged(),
      ),
    );
  }

  /// 点击分区:两侧翻页、中间切控制条。日漫(RTL)左右镜像(左=下一页,符合右起阅读)。
  void _onTapUp(double x, double width) {
    _focus.requestFocus(); // 点内容夺回键盘焦点(用过进度条后方向键仍能翻页)
    // 手势关掉 / 条漫:任意点击只切控制条(不翻页)。
    // 条漫 / 竖翻:任意点击只切控制条(翻页交给滑动 / 按键 / 滚轮)。
    if (!(_store?.readerGestures ?? true) ||
        _mode == ReaderMode.webtoon ||
        _mode == ReaderMode.vertical ||
        width <= 0) {
      _setOverlay(!_overlay);
      return;
    }
    final left = width * 0.30;
    final right = width * 0.70;
    if (x >= left && x <= right) {
      _setOverlay(!_overlay); // 中间:切控制条
      return;
    }
    if (_pageZoomed) return; // 放大态:两侧点击不翻页(正在看细节 / 平移)
    // 右侧默认前进(下一页);日漫 RTL 与「反转翻页方向」各镜像一次(XOR)。
    var forward = x >= right;
    if (_rtl) forward = !forward;
    if (_store?.invertTapZones ?? false) forward = !forward;
    _turn(forward ? 1 : -1);
  }

  // 控制条显隐 + 联动系统栏(收起控制条 = 沉浸,隐藏 Android 状态/导航栏)。
  void _setOverlay(bool v) {
    setState(() => _overlay = v);
    _applySystemUi();
  }

  void _applySystemUi() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    SystemChrome.setEnabledSystemUIMode(
        _overlay ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  // 屏幕方向锁(仅移动端):自动 / 竖屏 / 横屏。
  void _applyOrientation() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    SystemChrome.setPreferredOrientations(
        switch (_store?.readerOrientation ?? ReaderOrientation.auto) {
      ReaderOrientation.portrait => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
      ReaderOrientation.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      ReaderOrientation.auto => DeviceOrientation.values,
    });
  }

  // 阅读器底色(不显示全局背景图时)。
  Color _bgColor() => switch (_store?.readerBg ?? ReaderBackground.dark) {
        ReaderBackground.dark => const Color(0xFF050807),
        ReaderBackground.black => const Color(0xFF000000),
        ReaderBackground.white => const Color(0xFFFFFFFF),
        ReaderBackground.sepia => const Color(0xFFF6ECD8),
      };

  // 色彩滤镜:按需嵌套 ColorFiltered(对比度 → 纸色 → 黑白 → 反色)。
  Widget _filtered(Widget child) {
    final s = _store;
    if (s == null) return child;
    var w = child;
    if (s.cfContrast != 1.0) {
      w = ColorFiltered(colorFilter: _contrastFilter(s.cfContrast), child: w);
    }
    if (s.cfSepia) w = ColorFiltered(colorFilter: _sepiaFilter, child: w);
    if (s.cfGrayscale) {
      w = ColorFiltered(colorFilter: _grayscaleFilter, child: w);
    }
    if (s.cfInvert) w = ColorFiltered(colorFilter: _invertFilter, child: w);
    return w;
  }

  static const ColorFilter _grayscaleFilter = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0,
  ]);
  static const ColorFilter _invertFilter = ColorFilter.matrix(<double>[
    -1, 0, 0, 0, 255, //
    0, -1, 0, 0, 255, //
    0, 0, -1, 0, 255, //
    0, 0, 0, 1, 0,
  ]);
  static const ColorFilter _sepiaFilter = ColorFilter.matrix(<double>[
    0.393, 0.769, 0.189, 0, 0, //
    0.349, 0.686, 0.168, 0, 0, //
    0.272, 0.534, 0.131, 0, 0, //
    0, 0, 0, 1, 0,
  ]);
  static ColorFilter _contrastFilter(double c) {
    final t = 127.5 * (1 - c);
    return ColorFilter.matrix(<double>[
      c, 0, 0, 0, t, //
      0, c, 0, 0, t, //
      0, 0, c, 0, t, //
      0, 0, 0, 1, 0,
    ]);
  }

  // 首次打开:开「自动判断条漫」且本漫画无手动覆盖时,解首页宽高比,
  // 高瘦(条漫)图自动切滚动模式(不写覆盖:下次仍按图判;手动切才固定)。
  void _maybeAutoDetect() {
    final s = _store;
    if (s == null || !s.autoDetectMode) return;
    if (s.mangaMode(_mangaKey) != null) return; // 用户已手动指定
    if (_mode == ReaderMode.webtoon || _flat.isEmpty) return;
    final stream =
        _providerFor(_flat.first.img).resolve(const ImageConfiguration());
    void done() {
      final l = _detectListener;
      if (l != null) _detectStream?.removeListener(l);
      _detectStream = null;
      _detectListener = null;
    }

    final l = ImageStreamListener((info, _) {
      done();
      final w = info.image.width, h = info.image.height;
      if (!mounted || w <= 0) return;
      if (h / w > 1.8 &&
          _mode != ReaderMode.webtoon &&
          s.mangaMode(_mangaKey) == null) {
        setState(() => _mode = ReaderMode.webtoon);
      }
    }, onError: (_, __) => done());
    _detectStream = stream;
    _detectListener = l;
    stream.addListener(l);
  }

  // 音量键翻页(Android):注册回调 + 引用计数式激活。音量下=下一页(阅读顺序)。
  void _enableVolumeKeys() {
    _volKeyOn = true;
    ReaderKeys.setHandler((d) {
      if (mounted) _turn(d);
    });
    if (_volKeyCount++ == 0) ReaderKeys.setActive(true);
  }

  void _disableVolumeKeys() {
    _volKeyOn = false;
    if (--_volKeyCount == 0) {
      ReaderKeys.setActive(false);
      ReaderKeys.clearHandler();
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
        scrollDirection:
            _mode == ReaderMode.vertical ? Axis.vertical : Axis.horizontal,
        reverse: _rtl, // 日漫:右→左翻
        // 预加载开启时提前**建好相邻页的 UI**(配合图片解码预载 → 翻页零加载)。
        allowImplicitScrolling: (_store?.preload ?? 0) > 0,
        itemCount: count,
        onPageChanged: (p) => _onFlatChanged(_flatForPage(p)),
        itemBuilder: (_, p) => _PageTurn(
          // 内容稳定 key:缩放状态绑到「逻辑页」而非 PageView 槽位,
          // 双页/模式切换时不会把旧页的放大态套到别的页上。
          key: ValueKey(_pageKey(p)),
          controller: _ctrl,
          index: p,
          enabled: turn,
          child: _zoomable(_pagedItem(p), active: p == _pageForFlat(_curFlat)),
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

  // 逻辑页的稳定标识(章 index + 章内页码,唯一且不随 PageView 槽位变化)。
  String _pageKey(int slot) {
    if (!_dualActive) {
      final f = _flat[slot];
      return '${f.chapterIndex}:${f.localPage}';
    }
    final a = _flat[2 * slot];
    final b = (2 * slot + 1) < _flat.length ? _flat[2 * slot + 1] : null;
    return '${a.chapterIndex}:${a.localPage}|'
        '${b == null ? '' : '${b.chapterIndex}:${b.localPage}'}';
  }

  // 缩放:双指恒可缩放;双击缩放按设置开关(仅中间带,不与两侧翻页手势抢)。
  // active=false(非当前页)时会复位缩放,翻回来不再停在放大态。
  Widget _zoomable(Widget child, {bool active = true}) => _ZoomableView(
        doubleTap: _dtZoom,
        active: active,
        centerBandOnly: _store?.readerGestures ?? true,
        onZoomChanged: (z) {
          if (!active) return;
          if (z != _pageZoomed) setState(() => _pageZoomed = z);
        },
        child: child,
      );

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
      itemBuilder: (_, i) {
        final gap = _store?.webtoonGap ?? 0;
        return Padding(
          padding: EdgeInsets.only(top: i > 0 ? gap : 0),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: _image(_flat[i].img, BoxFit.fitWidth, fullWidth: true),
            ),
          ),
        );
      },
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
                onChangeEnd: (_) => _focus.requestFocus(),
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
                    onChangeEnd: (_) => _focus.requestFocus(),
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

  // 阅读设置面板(复用 lib/ui 的 showAppSheet + AppSwitchRow/AppSliderRow)。
  void _openSettings() {
    showAppSheet<void>(
      context,
      title: '阅读设置',
      bodyPadding: const EdgeInsets.fromLTRB(20, 16, 16, 24),
      body: (ctx, setSheet) {
        final p = ctx.palette;
        void apply(VoidCallback f) {
          f();
          setSheet(() {});
        }

        TextStyle label(Color c) =>
            TextStyle(color: c, fontSize: 12);
        return Column(
          spacing: 5,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('阅读模式', style: label(p.textMuted)),
            const SizedBox(height: 8),
            SegmentedButton<ReaderMode>(
              segments: const [
                ButtonSegment(value: ReaderMode.paged, label: Text('普通')),
                ButtonSegment(value: ReaderMode.pagedRtl, label: Text('日漫')),
                ButtonSegment(value: ReaderMode.vertical, label: Text('竖翻')),
                ButtonSegment(value: ReaderMode.webtoon, label: Text('滚动')),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => apply(() => _switchMode(s.first)),
            ),
            AppSwitchRow(
              title: '自动判断条漫',
              subtitle: '高瘦长条漫画自动用滚动模式(未手动指定时)',
              value: _store?.autoDetectMode ?? true,
              onChanged: (v) => apply(() => _store?.autoDetectMode = v),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
              subtitleSize: 11,
            ),
            if (_mode == ReaderMode.webtoon) ...[
              const SizedBox(height: 8),
              AppSliderRow(
                icon: Icons.aspect_ratio_rounded,
                iconColor: p.textMuted,
                label: '横屏内容宽度',
                value: (_store?.webtoonWidth ?? 0.5).clamp(0.3, 1.0),
                min: 0.3,
                max: 1.0,
                divisions: 14,
                pct: true,
                valueWidth: 42,
                valueFontSize: 12,
                onChanged: (v) => apply(() {
                  _store?.webtoonWidth = v;
                  setState(() {}); // 阅读器按新宽度即时重建
                }),
              ),
              Text('仅横屏生效 · 越窄一屏看得越长',
                  style: TextStyle(color: p.textMuted, fontSize: 11)),
              AppSliderRow(
                icon: Icons.density_medium_rounded,
                iconColor: p.textMuted,
                label: '页间距',
                value: (_store?.webtoonGap ?? 0).clamp(0, 40),
                min: 0,
                max: 40,
                divisions: 8,
                valueWidth: 42,
                valueFontSize: 12,
                onChanged: (v) => apply(() {
                  _store?.webtoonGap = v;
                  setState(() {}); // 阅读器按新间距即时重建
                }),
              ),
            ],
            AppSwitchRow(
              title: '双页同看',
              subtitle: '横向翻页模式下并排显示两页',
              value: _dual,
              onChanged:
                  (_mode == ReaderMode.paged || _mode == ReaderMode.pagedRtl)
                      ? (v) => apply(() => _setDual(v))
                      : null,
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
              subtitleSize: 11,
            ),
            AppSwitchRow(
              title: '允许双击缩放',
              value: _dtZoom,
              onChanged: (v) => apply(() {
                setState(() => _dtZoom = v);
                _store?.doubleTapZoom = v;
              }),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
            ),
            AppSwitchRow(
              title: '展示页码',
              value: _showPageNum,
              onChanged: (v) => apply(() {
                setState(() => _showPageNum = v);
                _store?.showPageNumber = v;
              }),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
            ),
            AppSwitchRow(
              title: '跨章提示',
              subtitle: '连读进入下一章时提示章节名',
              value: _store?.chapterToast ?? true,
              onChanged: (v) => apply(() => _store?.chapterToast = v),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
              subtitleSize: 11,
            ),
            const SizedBox(height: 6),
            Text('色彩 / 底色', style: label(p.textMuted)),
            const SizedBox(height: 8),
            SegmentedButton<ReaderBackground>(
              segments: const [
                ButtonSegment(value: ReaderBackground.dark, label: Text('深色')),
                ButtonSegment(value: ReaderBackground.black, label: Text('纯黑')),
                ButtonSegment(value: ReaderBackground.white, label: Text('白')),
                ButtonSegment(value: ReaderBackground.sepia, label: Text('纸')),
              ],
              selected: {_store?.readerBg ?? ReaderBackground.dark},
              showSelectedIcon: false,
              onSelectionChanged: (sel) => apply(() {
                _store?.readerBg = sel.first;
                setState(() {});
              }),
            ),
            Text('底色在「未显示全局背景图」时生效',
                style: TextStyle(color: p.textMuted, fontSize: 11)),
            AppSwitchRow(
              title: '黑白',
              value: _store?.cfGrayscale ?? false,
              onChanged: (v) => apply(() {
                _store?.cfGrayscale = v;
                setState(() {});
              }),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
            ),
            AppSwitchRow(
              title: '护眼纸色',
              subtitle: '暖色纸张色调,久读护眼',
              value: _store?.cfSepia ?? false,
              onChanged: (v) => apply(() {
                _store?.cfSepia = v;
                setState(() {});
              }),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
              subtitleSize: 11,
            ),
            AppSwitchRow(
              title: '反色',
              subtitle: '暗色漫画 / 夜间反相',
              value: _store?.cfInvert ?? false,
              onChanged: (v) => apply(() {
                _store?.cfInvert = v;
                setState(() {});
              }),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
              subtitleSize: 11,
            ),
            AppSliderRow(
              icon: Icons.contrast_rounded,
              iconColor: p.textMuted,
              label: '对比度',
              value: (_store?.cfContrast ?? 1.0).clamp(0.5, 1.5),
              min: 0.5,
              max: 1.5,
              divisions: 20,
              valueWidth: 42,
              valueFontSize: 12,
              onChanged: (v) => apply(() {
                _store?.cfContrast = v;
                setState(() {});
              }),
            ),
            const SizedBox(height: 6),
            Text('手势', style: label(p.textMuted)),
            AppSwitchRow(
              title: '点击分区翻页',
              subtitle: '屏幕左/右侧点击翻页,中间切控制条',
              value: _store?.readerGestures ?? true,
              onChanged: (v) => apply(() => _store?.readerGestures = v),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
              subtitleSize: 11,
            ),
            AppSwitchRow(
              title: '反转翻页方向',
              subtitle: '左侧点击 = 下一页,右侧 = 上一页(左手 / 习惯反转)',
              value: _store?.invertTapZones ?? false,
              onChanged: (v) => apply(() => _store?.invertTapZones = v),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
              subtitleSize: 11,
            ),
            if (Platform.isAndroid)
              AppSwitchRow(
                title: '音量键翻页',
                subtitle: '音量下 = 下一页,音量上 = 上一页',
                value: _store?.volumeKeyPaging ?? false,
                onChanged: (v) => apply(() {
                  _store?.volumeKeyPaging = v;
                  if (v && !_volKeyOn) {
                    _enableVolumeKeys();
                  } else if (!v && _volKeyOn) {
                    _disableVolumeKeys();
                  }
                }),
                dense: true,
                titleSize: 13.5,
                titleWeight: FontWeight.w600,
                subtitleSize: 11,
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
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
              ),
            ),
            const SizedBox(height: 6),
            Text('屏幕', style: label(p.textMuted)),
            AppSwitchRow(
              title: '常亮屏幕',
              subtitle: '阅读时不自动息屏',
              value: _store?.keepScreenOn ?? true,
              onChanged: (v) => apply(() {
                _store?.keepScreenOn = v;
                // 即时生效:开→拿锁,关→放锁(与全局引用计数配对)。
                if (v && !_wakeOn) {
                  _wakeOn = true;
                  if (_wakeCount++ == 0) WakelockPlus.enable();
                } else if (!v && _wakeOn) {
                  _wakeOn = false;
                  if (--_wakeCount == 0) WakelockPlus.disable();
                }
              }),
              dense: true,
              titleSize: 13.5,
              titleWeight: FontWeight.w600,
              subtitleSize: 11,
            ),
            if (Platform.isAndroid || Platform.isIOS) ...[
              const SizedBox(height: 4),
              SegmentedButton<ReaderOrientation>(
                segments: const [
                  ButtonSegment(
                      value: ReaderOrientation.auto, label: Text('自动')),
                  ButtonSegment(
                      value: ReaderOrientation.portrait, label: Text('竖屏')),
                  ButtonSegment(
                      value: ReaderOrientation.landscape, label: Text('横屏')),
                ],
                selected: {_store?.readerOrientation ?? ReaderOrientation.auto},
                showSelectedIcon: false,
                onSelectionChanged: (sel) => apply(() {
                  _store?.readerOrientation = sel.first;
                  _applyOrientation();
                }),
              ),
            ],
            const SizedBox(height: 6),
            Text('亮度', style: label(p.textMuted)),
            AppSliderRow(
              leading: Icon(Icons.nightlight_round, size: 18, color: p.textMuted),
              value: _brightness,
              min: 0.25,
              max: 1.0,
              showValueText: false,
              trailing:
                  Icon(Icons.wb_sunny_rounded, size: 18, color: p.textMuted),
              onChanged: (v) => apply(() {
                setState(() => _brightness = v);
                _store?.brightness = v;
              }),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _itemPos.itemPositions.removeListener(_onWebtoonScroll);
    // 摘掉未完成的自动判断监听(否则 State 被挂在挂起的图片请求上)。
    final dl = _detectListener;
    if (dl != null) _detectStream?.removeListener(dl);
    _ctrl.dispose();
    _focus.dispose();
    if (_volKeyOn) _disableVolumeKeys(); // 注销音量键(引用计数)
    if (_wakeOn && --_wakeCount == 0) {
      WakelockPlus.disable(); // 最后一个持锁的阅读器退出才息屏
    }
    // 仅最后一个阅读器退出才恢复系统栏 / 解方向锁;pushReplacement 重叠期(新页已
    // 在 initState 设好沉浸/方向锁)不清掉,避免闪回或丢失方向锁。
    if (--_uiCount == 0 && (Platform.isAndroid || Platform.isIOS)) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); // 恢复系统栏
      SystemChrome.setPreferredOrientations(DeviceOrientation.values); // 解方向锁
    }
    super.dispose();
  }
}

/// 可缩放视图:双指恒可缩放;双击缩放/复位按需开启。
/// 日漫翻页效果:随 PageView 滚动,把每页绕「书脊」做透视折叠 + 一道边缘阴影,
/// 读起来像翻纸。静止(t==0)时不套任何变换层(桌面性能 + 不影响缩放命中)。
class _PageTurn extends StatelessWidget {
  const _PageTurn({
    super.key,
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
  const _ZoomableView({
    required this.child,
    this.doubleTap = true,
    this.active = true,
    this.centerBandOnly = false,
    this.onZoomChanged,
  });
  final Widget child;
  final bool doubleTap;

  /// 是否为当前页;从 true 变 false(翻走)时复位缩放 —— 翻回来不再停在放大态。
  final bool active;

  /// 双击缩放只在中间带(30%~70%)触发,两侧让给外层翻页手势:
  /// 侧边快速点击不会被并成双击而误放大,也没有 300ms 等待。
  final bool centerBandOnly;

  /// 放大态变化回调(外层据此在放大时禁用点击翻页)。
  final ValueChanged<bool>? onZoomChanged;

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
    if (z != _zoomed) {
      setState(() => _zoomed = z);
      widget.onZoomChanged?.call(z);
    }
  }

  @override
  void didUpdateWidget(covariant _ZoomableView old) {
    super.didUpdateWidget(old);
    // 翻离当前页:复位缩放。修主 bug「返回上一页会莫名放大」——
    // 之前缩放态随页面被缓存,翻回来还停在放大。
    if (old.active && !widget.active && _tc.value != Matrix4.identity()) {
      // 直接改字段、不走 setState:didUpdateWidget 之后本就会 build,而此刻处于
      // 构建期,监听器 _onXform 里的 setState 会抛错,故先摘监听再改值。
      _tc.removeListener(_onXform);
      _tc.value = Matrix4.identity();
      _zoomed = false;
      _tc.addListener(_onXform);
    }
  }

  @override
  void dispose() {
    _tc.removeListener(_onXform);
    _tc.dispose();
    super.dispose();
  }

  // 以某点为中心,在 放大(2.5x)/复位 之间切换。
  void _toggleZoomAt(Offset pos) {
    if (_tc.value != Matrix4.identity()) {
      _tc.value = Matrix4.identity(); // 已放大 → 复位
    } else {
      const s = 2.5;
      // 缩放置对角、平移置末列(-pos*(s-1) 使该点不动)。
      _tc.value = Matrix4.identity()
        ..setEntry(0, 0, s)
        ..setEntry(1, 1, s)
        ..setEntry(0, 3, -pos.dx * (s - 1))
        ..setEntry(1, 3, -pos.dy * (s - 1));
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
    if (!widget.centerBandOnly) {
      // 无翻页分区冲突(手势关时):整页双击缩放。
      return GestureDetector(
        onDoubleTapDown: (d) => _tapPos = d.localPosition,
        onDoubleTap: () => _toggleZoomAt(_tapPos),
        child: viewer,
      );
    }
    // 有翻页分区:双击识别器只铺中间带,两侧不放识别器 → 侧边点击直接翻页,
    // 不再被并成双击。translucent 让中间带的单击穿透到外层(切控制条),
    // 双指捏合也穿透到底层 viewer;仅「中间带双击」被这里接住做缩放。
    return LayoutBuilder(
      builder: (ctx, cons) {
        final band = cons.maxWidth * 0.30;
        return Stack(
          children: [
            Positioned.fill(child: viewer),
            Positioned(
              left: band,
              right: band,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTapDown: (d) => _tapPos =
                    Offset(band + d.localPosition.dx, d.localPosition.dy),
                onDoubleTap: () => _toggleZoomAt(_tapPos),
              ),
            ),
          ],
        );
      },
    );
  }
}
