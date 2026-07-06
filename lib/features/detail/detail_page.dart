import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/download_store.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../app/ui_signals.dart';
import '../../core/bangumi/bangumi_api.dart';
import '../../core/color/cover_palette.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../common/animations.dart';
import '../common/transitions.dart';
import '../library/manga_cover.dart';
import '../reader/reader_page.dart';
import 'bangumi_search_sheet.dart';

class DetailPage extends StatefulWidget {
  const DetailPage(
      {super.key, required this.manga, required this.meta, this.heroTag});

  final Manga manga;
  final SourceMeta meta;

  /// 非空时封面用 Hero 从点击处的封面飞入(须与来源封面同 tag)。
  final Object? heroTag;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final MangaSource _source = buildSource(widget.meta);
  Map<String, String> get _imgHeaders => imageHeadersOf(widget.meta);
  List<Chapter>? _chapters;
  String? _error;
  Manga? _detail; // 完整详情(简介/分级/作者),异步补,失败则退回列表级信息
  bool _descExpanded = false;
  CoverPalette? _cover; // 封面主色(KMeans),null=未算好/失败 → 退回主题色
  String? _paletteFor; // 已算过取色的封面 url(避免重复算)
  BangumiInfo? _bgm; // Bangumi 评分(置信匹配到才有,否则 null)
  bool _bgmLoading = true; // Bangumi 匹配中(区分「加载中」和「没匹配到」)
  bool _bgmSummaryExpanded = false; // Bangumi 简介是否展开
  late Object _tintToken; // 全局背景封面色的栈 token(本页在栈,离开出栈)
  Color? _coverTint; // 算好的封面色(取消返回时用它重新压栈)
  bool _tintPushed = true; // 封面色当前是否在栈里
  ModalRoute<Object?>? _route; // 监听本页路由动画,返回一开始就出栈(不等 dispose)

  /// 渲染用的合并信息:优先完整详情,字段缺失时退回列表传入的 [widget.manga]。
  Manga get _manga {
    final d = _detail;
    if (d == null) return widget.manga;
    return Manga(
      id: widget.manga.id,
      title: d.title.isNotEmpty ? d.title : widget.manga.title,
      cover: (d.cover != null && d.cover!.isNotEmpty) ? d.cover : widget.manga.cover,
      url: (d.url != null && d.url!.isNotEmpty) ? d.url : widget.manga.url,
      authors: d.authors.isNotEmpty ? d.authors : widget.manga.authors,
      genres: d.genres.isNotEmpty ? d.genres : widget.manga.genres,
      description: (d.description != null && d.description!.isNotEmpty)
          ? d.description
          : widget.manga.description,
      status: d.status != MangaStatus.unknown ? d.status : widget.manga.status,
    );
  }

  @override
  void initState() {
    super.initState();
    _tintToken = DetailTint.push(); // 进入详情:入栈(取色算好后 update)
    _load();
    _loadDetail();
    _extractPalette();
    _loadBangumi();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = ModalRoute.of(context);
    if (r != _route) {
      _route?.animation?.removeStatusListener(_onRouteAnim);
      _route = r;
      _route?.animation?.addStatusListener(_onRouteAnim);
    }
  }

  // 本页路由的入场动画:reverse/dismissed = 正在返回 → 立刻把封面色出栈,
  // 背景在「离开动画」里就渐变回设置色,而不是等到已经在书架上才闪一下。
  void _onRouteAnim(AnimationStatus s) {
    final leaving =
        s == AnimationStatus.reverse || s == AnimationStatus.dismissed;
    if (leaving && _tintPushed) {
      _tintPushed = false;
      DetailTint.pop(_tintToken);
    } else if (!leaving && !_tintPushed && mounted) {
      _tintPushed = true; // 取消返回手势 → 重新压回封面色
      _tintToken = DetailTint.push(_coverTint);
    }
  }

  /// 去 Bangumi 查评分/元数据。优先用手动绑定的条目;否则标题置信匹配。
  /// 匹配不上不再静默——展示「未找到」+ 手动搜索入口。
  Future<void> _loadBangumi() async {
    final key = '${widget.meta.id}:${widget.manga.id}';
    final bound = LibraryScope.read(context).bangumiBindingFor(key);
    BangumiInfo? info;
    if (bound != null) {
      // 有手动绑定:只认它。加载失败(如条目已 404 / 暂时断网)**不回退自动匹配**,
      // 否则会用一个「可能正是用户当初否掉的」错误条目悄悄顶替。留 null → 显示未找到/重新匹配,
      // 且保留绑定(网络恢复后下次自然加载回来)。
      info = await BangumiApi.fromId(bound);
    } else {
      info = await BangumiApi.lookup(widget.manga.title);
    }
    if (!mounted) return;
    setState(() {
      _bgm = info;
      _bgmLoading = false;
    });
  }

  /// 手动搜索 Bangumi 并绑定(自动匹配不准/没匹配到时用)。绑定会持久化。
  Future<void> _openBangumiSearch() async {
    final picked = await showModalBottomSheet<BangumiCandidate>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => BangumiSearchSheet(initialQuery: widget.manga.title),
    );
    if (picked == null || !mounted) return;
    setState(() => _bgmLoading = true);
    // 先确认能拉到条目,**成功后再写绑定**——避免存下一个坏绑定、
    // 或因加载失败把刚选好的条目错误地掉回「未找到」空状态。
    final info = await BangumiApi.fromId(picked.id);
    if (!mounted) return;
    if (info == null) {
      setState(() => _bgmLoading = false); // 保留原卡片状态,只提示
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载该条目失败,请重试')),
      );
      return;
    }
    final key = '${widget.meta.id}:${widget.manga.id}';
    LibraryScope.read(context).setBangumiBinding(key, picked.id);
    setState(() {
      _bgm = info;
      _bgmLoading = false;
    });
  }

  /// 从封面算主色(KMeans),用来给详情页头部/按钮染色。失败静默,保持主题色。
  Future<void> _extractPalette() async {
    final url = _manga.cover;
    if (url == null || url.isEmpty || url == _paletteFor) return;
    _paletteFor = url;
    final pal = await extractCoverPalette(url, _imgHeaders);
    if (mounted && pal != null) {
      setState(() => _cover = pal);
      _coverTint = pal.primary;
      if (_tintPushed) {
        DetailTint.update(_tintToken, pal.primary); // 让全局背景在本页混入封面主题色
      }
    }
  }

  Future<void> _load() async {
    try {
      final page = await _source.getChapters(widget.manga.id);
      if (mounted) setState(() => _chapters = page.items);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadDetail() async {
    try {
      final d = await _source.getMangaDetail(widget.manga.id);
      if (mounted) setState(() => _detail = d);
      _extractPalette(); // 详情封面可能比列表更清晰,重算(url 不变则跳过)
    } catch (_) {
      // 详情拿不到不致命——头部退回列表级信息。
    }
  }

  Future<void> _openInBrowser() async {
    final raw = _manga.url;
    if (raw == null || raw.isEmpty) return;
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: SelectableText('打不开链接:$raw')),
      );
    }
  }

  void _openChapter(Chapter c, {int initialPage = 0}) {
    final list = _chapters ?? [c];
    var idx = list.indexWhere((x) => x.id == c.id);
    if (idx < 0) idx = 0;
    Navigator.of(context).push(
      appRoute(ReaderPage(
        source: _source,
        manga: widget.manga,
        chapters: list,
        index: idx,
        imageHeaders: _imgHeaders,
        initialPage: initialPage,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final acc = _cover?.primary ?? p.accent; // 封面主题色
    final store = LibraryScope.of(context); // 依赖:收藏/进度变了自动重建
    final dl = DownloadScope.of(context); // 依赖:下载状态变了刷新按钮
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        // 毛玻璃:模糊身后封面 + 顶部渐深遮罩,让返回/操作图标在任意封面上都清晰。
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.38),
                    Colors.black.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      // 全页融入封面主题色:顶部一层淡淡的封面色,向下渐隐,叠在全局背景之上。
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [acc.withValues(alpha: 0.16), Colors.transparent],
            stops: const [0.0, 0.55],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 760
              ? _wideBody(p, store, dl) // 横屏/桌面:左信息 + 右章节
              : _narrowBody(p, store, dl), // 竖屏:单列纵向滚动
        ),
      ),
    );
  }

  /// 竖屏:信息 + 章节单列纵向滚动。
  Widget _narrowBody(AppPalette p, LibraryStore store, DownloadStore dl) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: CustomScrollView(
            // 章节走惰性 SliverList:上千章也只建可见行(否则全建出来又卡又刷爆语义树)。
            slivers: [
              SliverToBoxAdapter(child: _hero(p)),
              SliverToBoxAdapter(child: _cta(p, store, dl)),
              SliverToBoxAdapter(child: _bangumiCard(p)),
              SliverToBoxAdapter(child: _synopsis(p)),
              ..._chapterSlivers(p, store, dl),
            ],
          ),
        ),
      );

  /// 横屏/桌面:左列固定宽度(封面/信息/按钮/简介,独立滚动),右列章节表(独立滚动)。
  Widget _wideBody(AppPalette p, LibraryStore store, DownloadStore dl) {
    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 380,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 28),
                child: Column(
                  children: [
                    _hero(p),
                    _cta(p, store, dl),
                    _bangumiCard(p),
                    _synopsis(p),
                  ],
                ),
              ),
            ),
            VerticalDivider(width: 1, thickness: 1, color: p.line),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  // 右列顶部让开透明 AppBar。
                  SliverToBoxAdapter(child: SizedBox(height: topInset)),
                  ..._chapterSlivers(p, store, dl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(AppPalette p) {
    final m = _manga;
    final grad = coverGradient(widget.manga.id);
    final cover = m.cover;
    final acc = _cover?.primary ?? p.accent;
    final gradTop = _cover?.primary ?? grad.first;
    final gradBot = _cover?.secondary ?? grad.last;
    return SizedBox(
      height: 268,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 450),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [gradTop.withValues(alpha: 0.9), gradBot],
              ),
            ),
          ),
          if (cover != null && cover.isNotEmpty)
            ExcludeSemantics(
              child: Opacity(
                opacity: 0.55,
                child: CachedNetworkImage(
                  cacheManager: appImageCache,
                  imageUrl: cover,
                  httpHeaders: _imgHeaders,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const SizedBox.shrink(),
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  p.background.withValues(alpha: 0.25),
                  p.background.withValues(alpha: 0.7),
                  p.background,
                ],
                stops: const [0.0, 0.65, 1.0],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 88,
                  child: MangaCover(
                    manga: m,
                    headers: _imgHeaders,
                    radius: 12,
                    heroTag: widget.heroTag,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 来源角标
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: acc.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(widget.meta.name,
                            style: TextStyle(
                                color: Color.lerp(acc, Colors.white, 0.35),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        m.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                      if (m.authors.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text('作者 · ${m.authors.join('、')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(color: p.textMuted, fontSize: 12)),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _pill(p, _statusText(m.status),
                              accent: true, accentColor: acc),
                          for (final t in m.genres.take(6)) _pill(p, t),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _statusText(MangaStatus s) {
    switch (s) {
      case MangaStatus.ongoing:
        return '● 连载中';
      case MangaStatus.completed:
        return '● 完结';
      case MangaStatus.hiatus:
        return '● 休刊';
      case MangaStatus.cancelled:
        return '● 停载';
      case MangaStatus.unknown:
        return '● 未知';
    }
  }

  Widget _pill(AppPalette p, String text,
      {bool accent = false, Color? accentColor}) {
    final a = accentColor ?? p.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: accent ? a.withValues(alpha: 0.16) : p.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent ? a.withValues(alpha: 0.45) : p.line),
      ),
      child: Text(text,
          style: TextStyle(
              color: accent ? Color.lerp(a, Colors.white, 0.25) : p.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700)),
    );
  }

  /// 继续阅读目标:有阅读进度且能在当前章节表里定位到那一章 → (章节, 上次读到第几页)。
  ({Chapter chapter, int page})? _resume(LibraryStore store) {
    final st = store.readState(widget.meta.id, widget.manga.id);
    final chapters = _chapters;
    if (st == null || st.lastChapterId.isEmpty || chapters == null) return null;
    for (final c in chapters) {
      if (c.id == st.lastChapterId) return (chapter: c, page: st.lastPage);
    }
    return null;
  }

  Widget _cta(AppPalette p, LibraryStore store, DownloadStore dl) {
    final chapters = _chapters;
    final fav = store.isFavorite(widget.meta.id, widget.manga.id);
    final resume = _resume(store); // 读过 → 主按钮变「继续阅读」
    final canRead = chapters != null && chapters.isNotEmpty;
    final acc = _cover?.primary ?? p.accent;
    final accOn = _cover?.onPrimary ?? p.onAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: !canRead
                  ? null
                  : (resume != null
                      ? () => _openChapter(resume.chapter,
                          initialPage: resume.page)
                      : () => _openChapter(chapters.first)), // 升序:第一条=第1话
              style: FilledButton.styleFrom(
                  backgroundColor: acc,
                  foregroundColor: accOn,
                  minimumSize: const Size.fromHeight(46)),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(resume != null ? Icons.play_circle_fill_rounded : Icons.play_arrow_rounded,
                      size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      resume != null ? '继续 · ${resume.chapter.name}' : '从头开始',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          _iconBtn(
            p,
            fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            active: fav,
            accent: acc,
            onTap: () => store.toggleFavorite(FavoriteEntry(
              sourceId: widget.meta.id,
              mangaId: widget.manga.id,
              title: widget.manga.title,
              cover: widget.manga.cover,
              addedAt: DateTime.now().millisecondsSinceEpoch,
            )),
          ),
          const SizedBox(width: 10),
          _iconBtn(
            p,
            Icons.download_rounded,
            accent: acc,
            onTap: (chapters != null && chapters.isNotEmpty)
                ? () => _downloadAll(dl, chapters)
                : null,
          ),
          if (_manga.url != null && _manga.url!.isNotEmpty) ...[
            const SizedBox(width: 10),
            _iconBtn(p, Icons.open_in_browser_rounded,
                accent: acc, onTap: _openInBrowser),
          ],
        ],
      ),
    );
  }

  Future<void> _downloadAll(DownloadStore dl, List<Chapter> chapters) async {
    final todo = chapters
        .where((c) => !dl.isDownloaded(widget.meta.id, widget.manga.id, c.id))
        .toList();
    if (todo.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载全部'),
        content: Text('将下载 ${todo.length} 话到本地,可离线阅读。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('下载')),
        ],
      ),
    );
    if (ok != true) return;
    for (final c in todo) {
      dl.enqueue(widget.meta, widget.manga, c, _imgHeaders);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已加入下载队列 · ${todo.length} 话')),
      );
    }
  }

  Widget _iconBtn(AppPalette p, IconData icon,
      {bool active = false, VoidCallback? onTap, Color? accent}) {
    final a = accent ?? p.accent;
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: active ? a.withValues(alpha: 0.16) : p.elevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? a : p.line),
        ),
        // 图标切换(如收藏♥↔♡)带缩放弹一下。
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(icon,
              key: ValueKey('$icon$active'),
              color: active ? a : p.textPrimary,
              size: 20),
        ),
      ),
    );
  }

  /// 简介卡:完整详情拿到后显示,长文可展开/收起。
  Widget _synopsis(AppPalette p) {
    final desc = (_manga.description ?? '').trim();
    if (desc.isEmpty) return const SizedBox.shrink();
    final acc = _cover?.primary ?? p.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(context.radius),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('简介',
                style: TextStyle(
                    color: acc,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0)),
            const SizedBox(height: 8),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: Text(
                desc,
                maxLines: _descExpanded ? null : 4,
                overflow: _descExpanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: TextStyle(
                    color: p.textPrimary.withValues(alpha: 0.82),
                    fontSize: 13,
                    height: 1.55),
              ),
            ),
            if (desc.length > 90) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(() => _descExpanded = !_descExpanded),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_descExpanded ? '收起' : '展开全部',
                        style: TextStyle(
                            color: acc,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                    AnimatedRotation(
                      turns: _descExpanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.keyboard_arrow_down_rounded,
                          color: acc, size: 18),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static const _bgmPink = Color(0xFFF09199); // Bangumi 品牌粉

  Widget _bgmIcon(AppPalette p, IconData icon, String tip, VoidCallback onTap) =>
      IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        color: p.textMuted,
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      );

  /// Bangumi 卡:加载中 / 未匹配(可手动搜索)/ 匹配到(评分 + 制作信息 + 简介)。
  Widget _bangumiCard(AppPalette p) {
    Widget shell(Widget child) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(context.radius),
              border: Border.all(color: p.line),
            ),
            child: child,
          ),
        );

    if (_bgmLoading) {
      return shell(Row(
        children: [
          const SizedBox(
              width: 15,
              height: 15,
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: _bgmPink)),
          const SizedBox(width: 10),
          Text('正在匹配 Bangumi…',
              style: TextStyle(color: p.textMuted, fontSize: 12)),
        ],
      ));
    }

    final b = _bgm;
    if (b == null) {
      return shell(Row(
        children: [
          Icon(Icons.search_off_rounded, size: 18, color: p.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Bangumi 未找到匹配条目',
                style: TextStyle(color: p.textMuted, fontSize: 12.5)),
          ),
          TextButton.icon(
            onPressed: _openBangumiSearch,
            icon: const Icon(Icons.search_rounded, size: 16),
            label: const Text('手动搜索'),
            style: TextButton.styleFrom(
                foregroundColor: _bgmPink,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          ),
        ],
      ));
    }

    final filled = (b.score / 2).floor();
    final half = (b.score / 2 - filled) >= 0.5;
    final metaBits = <String>[
      if (b.date.isNotEmpty) b.date,
      if (b.volumes > 0) '${b.volumes} 卷',
      if (b.eps > 0) '${b.eps} 话',
    ];
    return shell(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Bangumi',
                style: TextStyle(
                    color: _bgmPink,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0)),
            const Spacer(),
            _bgmIcon(p, Icons.search_rounded, '重新匹配', _openBangumiSearch),
            const SizedBox(width: 2),
            _bgmIcon(
                p,
                Icons.open_in_new_rounded,
                '在 Bangumi 打开',
                () => launchUrl(Uri.parse(b.url),
                    mode: LaunchMode.externalApplication)),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(b.score.toStringAsFixed(1),
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    height: 1.0)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    for (var i = 0; i < 5; i++)
                      Icon(
                          i < filled
                              ? Icons.star_rounded
                              : (i == filled && half
                                  ? Icons.star_half_rounded
                                  : Icons.star_border_rounded),
                          size: 15,
                          color: _bgmPink),
                  ]),
                  const SizedBox(height: 4),
                  Text('${b.rank > 0 ? '#${b.rank} · ' : ''}${b.votesLabel}',
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(b.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: p.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
        if (b.nameOrig.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(b.nameOrig,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textMuted, fontSize: 11)),
          ),
        if (metaBits.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(metaBits.join('  ·  '),
              style: TextStyle(color: p.textMuted, fontSize: 11)),
        ],
        if (b.infobox.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final row in b.infobox.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(row.$1,
                        style: TextStyle(color: p.textMuted, fontSize: 11)),
                  ),
                  Expanded(
                    child: Text(row.$2,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textPrimary, fontSize: 11)),
                  ),
                ],
              ),
            ),
        ],
        if (b.tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in b.tags.take(8))
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _bgmPink.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(t,
                      style: TextStyle(
                          color: Color.lerp(_bgmPink, Colors.white, 0.3),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ],
        if (b.summary.isNotEmpty) ...[
          const SizedBox(height: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                setState(() => _bgmSummaryExpanded = !_bgmSummaryExpanded),
            child: AnimatedSize(
              duration: LibraryStore.animationsEnabled
                  ? const Duration(milliseconds: 220)
                  : Duration.zero,
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: Text(b.summary,
                  maxLines: _bgmSummaryExpanded ? null : 3,
                  overflow: _bgmSummaryExpanded
                      ? TextOverflow.clip
                      : TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.textMuted, fontSize: 11.5, height: 1.5)),
            ),
          ),
        ],
      ],
    ));
  }

  Widget _chapterRow(
      AppPalette p, Chapter c, ChapterMark? mark, DownloadStore dl) {
    final read = mark != null;
    final finished = mark?.finished ?? false;
    final downloaded = dl.isDownloaded(widget.meta.id, widget.manga.id, c.id);
    final prog = dl.progressOf(widget.meta.id, widget.manga.id, c.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _openChapter(c,
            initialPage: (mark != null && !mark.finished) ? mark.page : 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(context.radius),
            border: Border.all(
                color: finished ? p.accent.withValues(alpha: 0.35) : p.line),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: read ? p.textMuted : p.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5)),
              ),
              if (finished)
                Icon(Icons.check_circle_rounded, size: 16, color: p.accent)
              else if (read)
                Text(
                    '读到 ${mark.page + 1}${mark.total > 0 ? '/${mark.total}' : ''}',
                    style: TextStyle(
                        color: p.accentSoft,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              // 下载状态/按钮
              GestureDetector(
                onTap: (downloaded || prog != null)
                    ? null
                    : () => dl.enqueue(
                        widget.meta, widget.manga, c, _imgHeaders),
                child: downloaded
                    ? Icon(Icons.download_done_rounded, size: 17, color: p.accent)
                    : prog != null
                        ? SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                                value: prog > 0 ? prog : null,
                                strokeWidth: 2,
                                color: p.accent))
                        : Icon(Icons.download_rounded,
                            size: 17, color: p.textMuted),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 18, color: p.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _chapterSlivers(
      AppPalette p, LibraryStore store, DownloadStore dl) {
    final acc = _cover?.primary ?? p.accent;
    final header = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Text(
          _chapters == null ? '章节' : '章节 · 共 ${_chapters!.length}',
          style: TextStyle(
              color: Color.lerp(p.textPrimary, acc, 0.4), // 融入封面主题色
              fontWeight: FontWeight.w700,
              fontSize: 13),
        ),
      ),
    );
    Widget stateBox(Widget child) => SliverToBoxAdapter(
          child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), child: child),
        );

    if (_error != null) {
      return [
        header,
        stateBox(Center(
            child: SelectableText('章节加载失败:\n$_error',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textMuted, fontSize: 12)))),
      ];
    }
    if (_chapters == null) {
      return [
        header,
        stateBox(const Padding(
            padding: EdgeInsets.symmetric(vertical: 26),
            child: Center(child: CircularProgressIndicator()))),
      ];
    }
    if (_chapters!.isEmpty) {
      return [
        header,
        stateBox(Column(
          children: [
            Text('没解析到章节',
                style: TextStyle(color: p.textPrimary, fontSize: 13)),
            const SizedBox(height: 8),
            SelectableText('id: ${widget.manga.id}\n${widget.manga.url ?? ''}',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textMuted, fontSize: 11)),
            const SizedBox(height: 8),
            Text('把此 id 填入「调试 → ⑦ → 保存详情页 HTML」存下来发我调',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textMuted, fontSize: 11)),
          ],
        )),
      ];
    }
    final list = _chapters!;
    return [
      header,
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        sliver: SliverList.builder(
          itemCount: list.length,
          // 每行从右侧滑入 + 淡入,首屏按下标错落(滚动时也「滚到哪滑到哪」)。
          itemBuilder: (ctx, i) => FadeSlideIn(
            dx: 32,
            offset: 0,
            delayMs: (i < 8 ? i : 8) * 22,
            child: _chapterRow(
                p,
                list[i],
                store.chapterMark(widget.meta.id, widget.manga.id, list[i].id),
                dl),
          ),
        ),
      ),
    ];
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteAnim);
    if (_tintPushed) DetailTint.pop(_tintToken); // 兜底:还在栈里就出栈
    _source.dispose();
    super.dispose();
  }
}
