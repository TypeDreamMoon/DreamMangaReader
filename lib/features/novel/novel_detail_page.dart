import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/library_store.dart';
import '../../app/download_coordinator_scope.dart';
import '../../app/novel_download_store.dart';
import '../../app/novel_library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../app/ui_signals.dart';
import '../../core/color/cover_palette.dart';
import '../../core/downloads/content_download_task.dart';
import '../../core/downloads/download_task.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/net/image_cache.dart';
import '../../core/novel/models.dart';
import '../../core/novel/novel_source.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import '../library/manga_cover.dart' show coverGradient;
import 'novel_cover.dart';
import 'novel_reader_page.dart';
import 'novel_source_sheet.dart';

/// 小说详情页。页面骨架与视觉语言**沿用漫画详情页**([DetailPage]):透明毛玻璃
/// 标题栏 + accent 渐隐底 + 760 断点(窄屏单列 / 宽屏左信息右目录)+ 同一套
/// hero / 操作条 / 简介卡 / 章节行。
///
/// 唯一刻意保留的小说侧差异是目录用 [ScrollablePositionedList]:小说动辄几百章且
/// 读者总在书中间,进页面要能直接定位到「读到哪」——SliverList 只能按偏移滚,
/// 给不了按下标定位。漫画那边靠「倒序」开关解决同一个问题,小说用不上倒序。
class NovelDetailPage extends StatefulWidget {
  const NovelDetailPage({
    super.key,
    required this.meta,
    required this.novel,
    this.heroTag,
    this.sourceBuilder = buildNovelSource,
    this.sourceCatalog,
  });

  final SourceMeta meta;
  final Novel novel;

  /// 列表页封面的 Hero tag —— 传了才有「封面飞入详情」的过渡。
  final Object? heroTag;

  final NovelSourceFactory sourceBuilder;
  final List<SourceMeta>? sourceCatalog;

  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage> {
  late SourceMeta _meta = widget.meta;
  late Novel _novel = widget.novel;
  NovelSource? _source;
  List<NovelChapter> _chapters = const [];
  Object? _error;
  bool _loading = true;
  bool _descriptionExpanded = false;
  int _loadGeneration = 0;

  CoverPalette? _cover; // 封面主色(KMeans),null=没封面/未算好 → 退回主题 accent
  String? _paletteFor; // 已取过色的封面 url(换源/补详情后才重算)
  late Object _tintToken; // 全局背景封面色的栈 token(本页在栈,离开出栈)
  Color? _coverTint; // 算好的封面色(取消返回手势时重新压栈)
  bool _tintPushed = true;
  ModalRoute<Object?>? _route; // 监听本页路由动画:开始返回就出栈,不等 dispose

  String get _libraryKey => NovelIdentity.remote(_meta.id, _novel.id).key;

  /// 页面强调色:封面主色 > 主题 accent。与漫画详情页同一套回退链。
  Color get _accent => _cover?.primary ?? context.palette.accent;

  @override
  void initState() {
    super.initState();
    _tintToken = DetailTint.push(); // 进入详情:入栈(取色算好后 update)
    unawaited(_load(_meta, _novel));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.animation?.removeStatusListener(_onRouteAnim);
      _route = route;
      _route?.animation?.addStatusListener(_onRouteAnim);
    }
  }

  // 返回动画一开始就把封面色出栈:背景在「离开动画」里就渐变回设置色,
  // 而不是等回到列表页才闪一下。取消返回手势则重新压回。
  void _onRouteAnim(AnimationStatus status) {
    final leaving = status == AnimationStatus.reverse ||
        status == AnimationStatus.dismissed;
    if (leaving && _tintPushed) {
      _tintPushed = false;
      DetailTint.pop(_tintToken);
    } else if (!leaving && !_tintPushed && mounted) {
      _tintPushed = true;
      _tintToken = DetailTint.push(_coverTint);
    }
  }

  /// 从封面图算主题色。小说很多是生成式封面(没有网络图),这时 [extractCoverPalette]
  /// 直接返回 null,页面照常用主题 accent —— 与漫画「取色失败就退回 accent」一致。
  Future<void> _extractPalette() async {
    final url = _novel.cover;
    if (url == null || url.isEmpty || url == _paletteFor) return;
    _paletteFor = url;
    final palette = await extractCoverPalette(url, imageHeadersOf(_meta));
    if (!mounted || palette == null || url != _novel.cover) return;
    setState(() => _cover = palette);
    _coverTint = palette.primary;
    // 让全局背景在本页混入封面主题色(与漫画详情页共用同一个 tint 栈)。
    if (_tintPushed) DetailTint.update(_tintToken, palette.primary);
  }

  Future<void> _load(SourceMeta meta, Novel seed) async {
    final generation = ++_loadGeneration;
    final previous = _source;
    _source = null;
    previous?.dispose();
    if (mounted) {
      setState(() {
        _meta = meta;
        _novel = seed;
        _chapters = const [];
        _error = null;
        _loading = true;
        _descriptionExpanded = false;
        _cover = null; // 换源 = 换封面,旧主题色不能留着
        _paletteFor = null;
      });
    }
    // 先用列表页带过来的封面取色:详情还在路上时页面就已经染上主题色了。
    unawaited(_extractPalette());

    NovelSource? source;
    try {
      source = widget.sourceBuilder(meta);
      if (!mounted || generation != _loadGeneration) {
        source.dispose();
        return;
      }
      _source = source;
      final values = await Future.wait<Object>([
        source.getNovelDetail(seed.id),
        _loadAllChapters(source, seed.id),
      ]);
      if (!mounted || generation != _loadGeneration || _source != source) {
        return;
      }
      setState(() {
        _novel = values[0] as Novel;
        _chapters = values[1] as List<NovelChapter>;
        _loading = false;
      });
      // 详情可能给了更好的封面(列表页往往只有缩略图)→ 用它重算一次。
      unawaited(_extractPalette());
    } catch (error) {
      if (!mounted || generation != _loadGeneration || _source != source) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<List<NovelChapter>> _loadAllChapters(
    NovelSource source,
    String novelId,
  ) async {
    final chapters = <NovelChapter>[];
    for (var page = 1; page <= 500; page++) {
      final result = await source.getNovelChapters(novelId, page: page);
      chapters.addAll(result.items);
      if (!result.hasNext || result.items.isEmpty) break;
    }
    return List.unmodifiable(chapters);
  }

  Future<void> _changeSource() async {
    final library = LibraryScope.read(context);
    final catalog = (widget.sourceCatalog ?? registeredSources)
        .where((source) =>
            source.isNovel &&
            (library.isSourceEnabled(source.id) || source.id == _meta.id))
        .toList(growable: false);
    final match = await showNovelSourceSheet(
      context,
      title: _novel.title,
      currentSourceId: _meta.id,
      sources: catalog,
      sourceBuilder: widget.sourceBuilder,
    );
    if (match == null || !mounted) return;
    await _load(match.meta, match.novel);
  }

  void _toggleFavorite() {
    final library = NovelLibraryScope.read(context);
    library.toggleRemoteFavorite(NovelLibraryEntry.remote(
      sourceId: _meta.id,
      novelId: _novel.id,
      title: _novel.title,
      authors: _novel.authors,
      cover: _novel.cover,
    ));
    setState(() {});
  }

  Future<void> _openBrowser() async {
    final uri = Uri.tryParse(_novel.url ?? '');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _openChapter(int index) {
    final source = _source;
    if (source == null) return;
    final meta = _meta;
    final novel = _novel;
    final chapters = _chapters;
    final downloads = NovelDownloadScope.read(context);
    Future<NovelDocument?> loadCached(NovelChapter chapter) async {
      final cached = await downloads.localDocument(
        meta.id,
        novel.id,
        chapter.id,
      );
      if (cached == null) return null;
      return NovelDocument(
        format: NovelDocumentFormat.html,
        content: cached.html,
        baseUrl: Uri.directory(cached.directory).toString(),
      );
    }

    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NovelReaderPage(
        novel: novel,
        chapters: chapters,
        initialIndex: index,
        libraryKey: NovelIdentity.remote(meta.id, novel.id).key,
        loadCachedDocument: loadCached,
        loadDocument: (chapter) async {
          final cached = await loadCached(chapter);
          if (cached != null) {
            return cached;
          }
          return source.getNovelDocument(novel.id, chapter.id);
        },
      ),
    ));
  }

  String _downloadTaskId(NovelChapter chapter) => contentDownloadTaskId(
        DownloadContentKind.novel,
        _meta.id,
        _novel.id,
        chapter.id,
      );

  Future<void> _downloadChapter(NovelChapter chapter) async {
    final legacy = NovelDownloadScope.read(context);
    if (legacy.isDownloaded(_meta.id, _novel.id, chapter.id)) return;
    final coordinator = DownloadCoordinatorScope.maybeRead(context);
    if (coordinator == null) {
      legacy.enqueue(_meta, _novel, chapter);
      return;
    }
    final taskId = _downloadTaskId(chapter);
    final existing = coordinator.task(taskId);
    if (existing == null) {
      await coordinator.enqueue(ContentDownloadTask.novel(
        sourceId: _meta.id,
        contentId: _novel.id,
        contentTitle: _novel.title,
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        now: DateTime.now().millisecondsSinceEpoch,
      ));
      return;
    }
    switch (existing.state) {
      case DownloadTaskState.paused:
        await coordinator.resume(taskId);
      case DownloadTaskState.failed || DownloadTaskState.cancelled:
        await coordinator.retry(taskId);
      case DownloadTaskState.resolving ||
            DownloadTaskState.queued ||
            DownloadTaskState.running ||
            DownloadTaskState.verifying ||
            DownloadTaskState.completed:
        return;
    }
  }

  Future<void> _downloadAll() async {
    final downloads = NovelDownloadScope.read(context);
    final coordinator = DownloadCoordinatorScope.maybeRead(context);
    final pending = _chapters.where((chapter) {
      if (downloads.isDownloaded(_meta.id, _novel.id, chapter.id)) {
        return false;
      }
      final task = coordinator?.task(_downloadTaskId(chapter));
      return task == null ||
          task.state == DownloadTaskState.paused ||
          task.state == DownloadTaskState.failed ||
          task.state == DownloadTaskState.cancelled;
    }).toList(growable: false);
    if (pending.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.detail_downloadAll),
        content: Text(context.l10n.detail_downloadNConfirm(pending.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.detail_download),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final chapter in pending) {
      await _downloadChapter(chapter);
    }
    if (mounted) {
      showAppNotify(context, context.l10n.detail_addedToQueueN(pending.length),
          kind: AppNotifyKind.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final novelLibrary = NovelLibraryScope.of(context);
    DownloadCoordinatorScope.maybeOf(context);
    final favorite = novelLibrary.entryFor(_libraryKey)?.favorite == true;
    final activeId = novelLibrary.progressFor(_libraryKey)?.chapterId;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        // 图标压在 hero 封面上,固定白色 + 身后毛玻璃遮罩(与漫画详情页同款),
        // 不用 palette —— 任意封面下都要看得清。
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            key: const Key('novel-change-source'),
            tooltip: context.l10n.novel_switchSource,
            onPressed: _loading ? null : _changeSource,
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
          const SizedBox(width: 4),
        ],
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
      body: _error != null
          ? AppErrorView(
              title: context.l10n.novel_loadFailed('$_error'),
              message: '${_meta.name} · ${_novel.title}',
              onRetry: () => _load(_meta, _novel),
            )
          : DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_accent.withValues(alpha: 0.16), Colors.transparent],
                  stops: const [0.0, 0.55],
                ),
              ),
              child: LayoutBuilder(
                builder: (context, c) => c.maxWidth >= 760
                    ? _wideBody(p, favorite, activeId)
                    : _narrowBody(p, favorite, activeId),
              ),
            ),
    );
  }

  /// 竖屏:hero + 操作条 + 简介 + 目录,单列纵向滚动。
  Widget _narrowBody(AppPalette p, bool favorite, String? activeId) => Center(
        child: ConstrainedBox(
          key: const Key('novel-detail-narrow'),
          constraints: const BoxConstraints(maxWidth: 820),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _hero(p)),
              SliverToBoxAdapter(child: _cta(p, favorite)),
              SliverToBoxAdapter(child: _synopsis(p)),
              SliverToBoxAdapter(
                child: _directory(
                  p,
                  activeId,
                  height: (MediaQuery.sizeOf(context).height * .72)
                      .clamp(460, 680)
                      .toDouble(),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          ),
        ),
      );

  /// 横屏/桌面:左列固定宽度(封面/信息/按钮/简介,独立滚动),右列目录(独立滚动)。
  Widget _wideBody(AppPalette p, bool favorite, String? activeId) {
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Center(
      child: ConstrainedBox(
        key: const Key('novel-detail-wide'),
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
                    _cta(p, favorite),
                    _synopsis(p),
                  ],
                ),
              ),
            ),
            VerticalDivider(width: 1, thickness: 1, color: p.line),
            Expanded(
              child: Padding(
                // 右列顶部让开透明 AppBar。
                padding: EdgeInsets.only(top: topInset),
                child: _directory(p, activeId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(AppPalette p) {
    final grad = coverGradient(_novel.id);
    final acc = _accent;
    final gradTop = _cover?.primary ?? grad.first;
    final gradBot = _cover?.secondary ?? grad.last;
    final cover = _novel.cover;
    final remote = Uri.tryParse(cover ?? '');
    final hasRemoteCover = remote != null &&
        (remote.scheme == 'http' || remote.scheme == 'https') &&
        remote.host.isNotEmpty;
    final authors = _novel.authors.where((value) => value.trim().isNotEmpty);
    final genres = _novel.genres.where((value) => value.trim().isNotEmpty);
    return SizedBox(
      key: const Key('novel-detail-hero'),
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
          if (hasRemoteCover)
            ExcludeSemantics(
              child: Opacity(
                opacity: 0.55,
                child: CachedNetworkImage(
                  cacheManager: appImageCache,
                  imageUrl: remote.toString(),
                  httpHeaders: imageHeadersOf(_meta),
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
                  child: NovelCover(
                    novel: _novel,
                    headers: imageHeadersOf(_meta),
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
                      AppPill(
                        text: _meta.name,
                        fill: acc.withValues(alpha: 0.16),
                        textColor: Color.lerp(acc, Colors.white, 0.35),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        radius: 6,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        _novel.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                      if (authors.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          context.l10n.detail_authorPrefix(authors.join('、')),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.textMuted, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _pill(p, _statusLabel(context, _novel.status),
                              accent: true, accentColor: acc),
                          for (final genre in genres.take(6)) _pill(p, genre),
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

  Widget _pill(AppPalette p, String text,
      {bool accent = false, Color? accentColor}) {
    final a = accentColor ?? p.accent;
    return AppPill(
      text: text,
      fill: accent ? a.withValues(alpha: 0.16) : p.surface,
      border: accent ? a.withValues(alpha: 0.45) : p.line,
      textColor: accent ? Color.lerp(a, Colors.white, 0.25) : p.textMuted,
    );
  }

  Widget _cta(AppPalette p, bool favorite) {
    final progress = NovelLibraryScope.read(context).progressFor(_libraryKey);
    final activeIndex = progress == null
        ? -1
        : _chapters.indexWhere((chapter) => chapter.id == progress.chapterId);
    final startIndex = activeIndex < 0 ? 0 : activeIndex;
    final canRead = !_loading && _chapters.isNotEmpty;
    final resumed = canRead && activeIndex >= 0;
    final acc = _accent;
    final accOn = _cover?.onPrimary ?? p.onAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: canRead ? () => _openChapter(startIndex) : null,
              style: FilledButton.styleFrom(
                  backgroundColor: acc,
                  foregroundColor: accOn,
                  minimumSize: const Size.fromHeight(46)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                      resumed
                          ? Icons.play_circle_fill_rounded
                          : Icons.play_arrow_rounded,
                      size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      resumed
                          ? context.l10n.detail_continueChapter(
                              _chapters[startIndex].title)
                          : context.l10n.detail_startFromBeginning,
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
            favorite ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            tooltip: favorite
                ? context.l10n.novel_removeFavorite
                : context.l10n.novel_addFavorite,
            active: favorite,
            accent: acc,
            onTap: _toggleFavorite,
          ),
          const SizedBox(width: 10),
          _iconBtn(
            p,
            Icons.download_rounded,
            tooltip: context.l10n.detail_downloadAll,
            accent: acc,
            onTap: canRead ? _downloadAll : null,
          ),
          if (_novel.url != null) ...[
            const SizedBox(width: 10),
            _iconBtn(
              p,
              Icons.open_in_browser_rounded,
              tooltip: context.l10n.novel_openInBrowser,
              accent: acc,
              onTap: _openBrowser,
            ),
          ],
        ],
      ),
    );
  }

  Widget _iconBtn(
    AppPalette p,
    IconData icon, {
    required String tooltip,
    bool active = false,
    Color? accent,
    VoidCallback? onTap,
  }) {
    final a = accent ?? p.accent;
    return Tooltip(
      message: tooltip,
      child: Pressable(
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
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(icon,
                key: ValueKey('$icon$active'),
                color:
                    onTap == null ? p.textMuted : (active ? a : p.textPrimary),
                size: 20),
          ),
        ),
      ),
    );
  }

  Widget _synopsis(AppPalette p) {
    final description = (_novel.description ?? '').trim();
    if (description.isEmpty) return const SizedBox.shrink();
    final canExpand = description.runes.length > 140;
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
            Text(context.l10n.detail_synopsis,
                style: TextStyle(
                    color: _accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0)),
            const SizedBox(height: 8),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: Text(
                description,
                key: const Key('novel-detail-description'),
                maxLines: _descriptionExpanded ? null : 10,
                overflow: _descriptionExpanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: TextStyle(
                    color: p.textPrimary.withValues(alpha: 0.82),
                    fontSize: 13,
                    height: 1.55),
              ),
            ),
            if (canExpand) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(
                    () => _descriptionExpanded = !_descriptionExpanded),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                        _descriptionExpanded
                            ? context.l10n.detail_collapse
                            : context.l10n.detail_expandAll,
                        style: TextStyle(
                            color: _accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                    AnimatedRotation(
                      turns: _descriptionExpanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.keyboard_arrow_down_rounded,
                          color: _accent, size: 18),
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

  /// 目录。[height] 非空 = 嵌在窄屏单列滚动里的定高区;为空 = 宽屏右列自己占满。
  Widget _directory(AppPalette p, String? activeId, {double? height}) {
    final activeIndex = activeId == null
        ? -1
        : _chapters.indexWhere((chapter) => chapter.id == activeId);
    final content = Column(
      children: [
        Padding(
          key: const Key('novel-detail-directory'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.novel_directory,
                  style: TextStyle(
                      // 与漫画章节表头同款:标题色向 accent 偏一点,融进页面主色。
                      color: Color.lerp(p.textPrimary, _accent, 0.4),
                      fontWeight: FontWeight.w700,
                      fontSize: 13),
                ),
              ),
              Text(
                context.l10n.novel_chaptersN(_chapters.length),
                style: TextStyle(color: p.textMuted, fontSize: 12.5),
              ),
            ],
          ),
        ),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_chapters.isEmpty)
          Expanded(child: EmptyState(title: context.l10n.novel_noChapters))
        else
          Expanded(
            child: ScrollablePositionedList.builder(
              key: ValueKey(
                'novel-directory-${_meta.id}-${_novel.id}-'
                '${_chapters.length}-$activeIndex',
              ),
              initialScrollIndex: activeIndex < 0 ? 0 : activeIndex,
              initialAlignment: activeIndex < 0 ? 0 : .18,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              itemCount: _chapters.length,
              itemBuilder: (context, index) => _chapterRow(
                p,
                index,
                activeId: activeId,
              ),
            ),
          ),
      ],
    );
    if (height == null) return content;
    return SizedBox(height: height, child: content);
  }

  Widget _chapterRow(
    AppPalette p,
    int index, {
    required String? activeId,
  }) {
    final chapter = _chapters[index];
    final previous = index == 0 ? null : _chapters[index - 1];
    final showVolume = chapter.volumeId != null &&
        (previous == null || previous.volumeId != chapter.volumeId);
    final downloads = NovelDownloadScope.read(context);
    final task = DownloadCoordinatorScope.maybeRead(context)?.task(
      _downloadTaskId(chapter),
    );
    final active = chapter.id == activeId;
    final row = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _openChapter(index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(context.radius),
            border: Border.all(
                color: active ? p.accent.withValues(alpha: 0.35) : p.line),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Text('${index + 1}',
                    style: TextStyle(
                        color: p.textMuted,
                        fontSize: 11,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ),
              Expanded(
                child: Text(chapter.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: active ? p.accentSoft : p.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5)),
              ),
              const SizedBox(width: 8),
              if (active)
                Icon(Icons.bookmark_rounded, size: 15, color: p.accent),
              if (active) const SizedBox(width: 8),
              AnimatedBuilder(
                animation: downloads,
                builder: (context, _) {
                  if (downloads.isDownloaded(_meta.id, _novel.id, chapter.id)) {
                    return Icon(Icons.download_done_rounded,
                        size: 17, color: p.accent);
                  }
                  if (task?.state == DownloadTaskState.completed) {
                    return Icon(Icons.download_done_rounded,
                        size: 17, color: p.accent);
                  }
                  final active = task != null &&
                      (task.state == DownloadTaskState.resolving ||
                          task.state == DownloadTaskState.queued ||
                          task.state == DownloadTaskState.running ||
                          task.state == DownloadTaskState.verifying);
                  if (active) {
                    return SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                          value: task.progress > 0 ? task.progress : null,
                          strokeWidth: 2,
                          color: p.accent),
                    );
                  }
                  final legacyFailure =
                      downloads.failureOf(_meta.id, _novel.id, chapter.id);
                  final failed = task?.state == DownloadTaskState.failed ||
                      task?.state == DownloadTaskState.cancelled ||
                      legacyFailure != null;
                  return GestureDetector(
                    onTap: () => _downloadChapter(chapter),
                    child: Tooltip(
                      message: !failed
                          ? context.l10n.novel_downloadChapter
                          : context.l10n.novel_retryDownload,
                      child: Icon(
                          !failed
                              ? Icons.download_rounded
                              : Icons.refresh_rounded,
                          size: 17,
                          color: failed ? p.statusFail : p.textMuted),
                    ),
                  );
                },
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 18, color: p.textMuted),
            ],
          ),
        ),
      ),
    );
    // 首屏按下标错落淡入 + 右侧滑入,与漫画章节表同一入场。
    final animated = FadeSlideIn(
      dx: 32,
      offset: 0,
      delayMs: (index < 8 ? index : 8) * 22,
      child: row,
    );
    if (!showVolume) {
      return active
          ? KeyedSubtree(
              key: const Key('novel-chapter-active'), child: animated)
          : animated;
    }
    final grouped = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
          child: Text(
            chapter.volumeTitle ?? '',
            style: TextStyle(
                color: p.accent,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0),
          ),
        ),
        animated,
      ],
    );
    return active
        ? KeyedSubtree(key: const Key('novel-chapter-active'), child: grouped)
        : grouped;
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteAnim);
    if (_tintPushed) DetailTint.pop(_tintToken); // 兜底:还在栈里就出栈
    _loadGeneration++;
    _source?.dispose();
    super.dispose();
  }
}

String _statusLabel(BuildContext context, NovelStatus status) =>
    switch (status) {
      NovelStatus.ongoing => context.l10n.novel_statusOngoing,
      NovelStatus.completed => context.l10n.novel_statusCompleted,
      NovelStatus.hiatus => context.l10n.novel_statusHiatus,
      NovelStatus.cancelled => context.l10n.novel_statusCancelled,
      NovelStatus.unknown => context.l10n.novel_statusUnknown,
    };
