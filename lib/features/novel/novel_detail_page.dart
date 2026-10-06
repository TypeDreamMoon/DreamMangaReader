import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/transitions.dart';
import '../../app/download_coordinator_scope.dart';
import '../../app/novel_download_store.dart';
import '../../app/novel_library_store.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/downloads/content_download_task.dart';
import '../../core/downloads/download_task.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/novel/novel_source.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import '../common/detail_body.dart';
import '../common/detail_cover_tint.dart';
import '../common/cross_source_sessions.dart';
import '../common/detail_author_line.dart';
import '../common/detail_cta.dart';
import '../detail/cross_source_sheet.dart';
import '../common/detail_hero.dart';
import '../common/detail_synopsis.dart';
import 'novel_cover.dart';
import 'novel_reader_page.dart';

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

class _NovelDetailPageState extends State<NovelDetailPage>
    with DetailCoverTint<NovelDetailPage> {
  late SourceMeta _meta = widget.meta;
  late Novel _novel = widget.novel;
  NovelSource? _source;
  List<NovelChapter> _chapters = const [];
  Object? _error;
  Object? _chaptersError;
  bool _loading = true;
  bool _chaptersLoading = true;
  bool _descriptionExpanded = false;
  int _loadGeneration = 0;
  int _chaptersNextPage = 1;
  String _chaptersNovelId = '';

  /// 目录分页的上限。真有源翻到第 500 页还说 hasNext,那多半是源坏了。
  static const int _maxChapterPages = 500;

  String get _libraryKey => NovelIdentity.remote(_meta.id, _novel.id).key;

  @override
  void initState() {
    super.initState();
    unawaited(_load(_meta, _novel));
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
        _chaptersError = null;
        _loading = true;
        _chaptersLoading = true;
        _chaptersNextPage = 1;
        _chaptersNovelId = seed.id;
        _descriptionExpanded = false;
      });
      resetCoverTint(); // 换源 = 换封面,旧主题色不能留着
    }
    // 先用列表页带过来的封面取色:详情还在路上时页面就已经染上主题色了。
    unawaited(updateCoverTint(_novel.cover, imageHeadersOf(_meta)));

    NovelSource? source;
    try {
      source = widget.sourceBuilder(meta);
      if (!mounted || generation != _loadGeneration) {
        source.dispose();
        return;
      }
      _source = source;
      // 详情和目录各走各的:目录以前要把最多 500 页全拉完才渲染一次,几百章的书
      // 要白等十几秒;和详情捆在一个 Future.wait 里,详情一失败目录也跟着没了。
      unawaited(_loadChapters(source, seed.id, generation));
      final detail = await source.getNovelDetail(seed.id);
      if (!mounted || generation != _loadGeneration || _source != source) {
        return;
      }
      setState(() {
        _novel = detail;
        _loading = false;
      });
      // 详情可能给了更好的封面(列表页往往只有缩略图)→ 用它重算一次。
      unawaited(updateCoverTint(_novel.cover, imageHeadersOf(_meta)));
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

  /// 目录边拉边显示:每翻到一页就往列表上追加一次,读者不用等到最后一页。
  Future<void> _loadChapters(
    NovelSource source,
    String novelId,
    int generation,
  ) async {
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _chaptersLoading = true;
      _chaptersError = null;
    });
    final collected = <NovelChapter>[..._chapters];
    try {
      for (var page = _chaptersNextPage; page <= _maxChapterPages; page++) {
        final result = await source.getNovelChapters(novelId, page: page);
        if (!mounted || generation != _loadGeneration || _source != source) {
          return;
        }
        collected.addAll(result.items);
        _chaptersNextPage = page + 1;
        setState(() => _chapters = List.unmodifiable(collected));
        if (!result.hasNext || result.items.isEmpty) break;
      }
      if (!mounted || generation != _loadGeneration || _source != source) {
        return;
      }
      setState(() => _chaptersLoading = false);
    } catch (error) {
      if (!mounted || generation != _loadGeneration || _source != source) {
        return;
      }
      setState(() {
        _chaptersError = error;
        _chaptersLoading = false;
      });
    }
  }

  void _retryChapters() {
    final source = _source;
    if (source == null || _chaptersLoading) return;
    unawaited(_loadChapters(source, _chaptersNovelId, _loadGeneration));
  }

  Future<void> _changeSource() async {
    final library = LibraryScope.read(context);
    final candidates = [
      for (final s in widget.sourceCatalog ?? registeredSources)
        if (s.isNovel && s.id != _meta.id && library.isSourceEnabled(s.id)) s,
    ];
    final picked = await showAppSheet<CrossSourcePick>(
      context,
      title: context.l10n.detail_switchSource,
      showCloseButton: true,
      resizeForKeyboard: true,
      heightFactor: 0.7,
      body: (ctx, setSheet) => CrossSourceSheet(
        title: _novel.title,
        sources: candidates,
        settings: library,
        sessionFactory: (meta) =>
            NovelCrossSourceSession(meta, builder: widget.sourceBuilder),
      ),
    );
    if (picked == null || !mounted) return;
    await _load(picked.meta, picked.item.payload as Novel);
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

  void _openChapter(int index, {bool resume = false}) {
    if (_source == null) return;
    final meta = _meta;
    final novel = _novel;
    final chapters = _chapters;
    NovelLibraryScope.read(context).rememberRemote(NovelLibraryEntry.remote(
      sourceId: meta.id,
      novelId: novel.id,
      title: novel.title,
      authors: novel.authors,
      cover: novel.cover,
    ));
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

    // 阅读器拿自己的 source:详情页那份是给目录用的,换源(或详情页自己被
    // 收掉)时会连着 dispose,已经打开的阅读器不能跟着一起废掉 —— 翻下一章
    // 就抛在这上面。句柄跟着路由走,阅读器一关就释放;路由没推成(连点保护)
    // 时 pushRoute 直接返回已完成的 future,同样立刻释放。
    final readerSource = widget.sourceBuilder(meta);
    unawaited(pushRoute(context, MaterialPageRoute<void>(
      builder: (_) => NovelReaderPage(
        novel: novel,
        chapters: chapters,
        initialIndex: index,
        libraryKey: NovelIdentity.remote(meta.id, novel.id).key,
        resumeFromHistory: resume,
        loadCachedDocument: loadCached,
        loadDocument: (chapter) async {
          final cached = await loadCached(chapter);
          if (cached != null) {
            return cached;
          }
          return readerSource.getNovelDocument(novel.id, chapter.id);
        },
      ),
    )).whenComplete(() {
      try {
        readerSource.dispose();
      } catch (_) {}
    }));
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
      // 详情挂了但目录还在,就照常渲染 —— 用列表页带来的书名封面顶着,
      // 总比把已经拿到的几百章一起丢掉强。
      body: _error != null && _chapters.isEmpty && !_chaptersLoading
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
                  colors: [coverAccent.withValues(alpha: 0.16), Colors.transparent],
                  stops: const [0.0, 0.55],
                ),
              ),
              child: DetailBody(
                narrowKey: const Key('novel-detail-narrow'),
                wideKey: const Key('novel-detail-wide'),
                info: [_hero(p), _cta(p, favorite), _synopsis(p)],
                // 目录自带滚动:窄屏给它一个不吃掉整屏的定高,宽屏铺满右列。
                listing: (wide) => DetailListing.fill(_directory(
                  p,
                  activeId,
                  height: wide
                      ? null
                      : (MediaQuery.sizeOf(context).height * .72)
                          .clamp(460, 680)
                          .toDouble(),
                )),
              ),
            ),
    );
  }

  Widget _hero(AppPalette p) {
    final authors =
        _novel.authors.where((value) => value.trim().isNotEmpty).toList();
    // 小说封面常是本地生成的(没有网络图)→ 只有真的是 http(s) 图才铺成背景大图。
    final remote = Uri.tryParse(_novel.cover ?? '');
    final hasRemoteCover = remote != null &&
        (remote.scheme == 'http' || remote.scheme == 'https') &&
        remote.host.isNotEmpty;
    return DetailHero(
      key: const Key('novel-detail-hero'),
      gradientSeed: _novel.id,
      palette: coverPalette,
      accent: coverAccent,
      cover: NovelCover(
        novel: _novel,
        headers: imageHeadersOf(_meta),
        radius: 12,
        heroTag: widget.heroTag,
      ),
      backdropUrl: hasRemoteCover ? remote.toString() : null,
      backdropHeaders: imageHeadersOf(_meta),
      sourceName: _meta.name,
      title: _novel.title,
      statusText: _statusLabel(context, _novel.status),
      genres:
          _novel.genres.where((value) => value.trim().isNotEmpty).toList(),
      // 小说没有「同作者作品」(那个页面跑在 MangaSource 上)→ 不给 onOpenAuthor,
      // 组件自动退回纯文本。
      authorLine: authors.isEmpty
          ? null
          : DetailAuthorLine(
              authors: authors,
              accent: coverAccent,
              keyPrefix: 'novel-author',
            ),
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
    final acc = coverAccent;
    return DetailCta(
      accent: acc,
      onAccent: coverPalette?.onPrimary ?? p.onAccent,
      resumed: resumed,
      resumeLabel: resumed ? _chapters[startIndex].title : '',
      // 「继续阅读」按钮:交给阅读器按保存的进度接着读。
      onPrimary: canRead ? () => _openChapter(startIndex, resume: true) : null,
      actions: [
        AppIconButton(
          icon:
              favorite ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          tooltip: favorite
              ? context.l10n.detail_removeFavorite
              : context.l10n.detail_addFavorite,
          active: favorite,
          accent: acc,
          onTap: _toggleFavorite,
        ),
        AppIconButton(
          icon: Icons.download_rounded,
          tooltip: context.l10n.detail_downloadAll,
          accent: acc,
          onTap: canRead ? _downloadAll : null,
        ),
        if (_novel.url != null)
          AppIconButton(
            icon: Icons.open_in_browser_rounded,
            tooltip: context.l10n.detail_openInBrowser,
            accent: acc,
            onTap: _openBrowser,
          ),
      ],
    );
  }

  Widget _synopsis(AppPalette p) => DetailSynopsis(
        text: (_novel.description ?? '').trim(),
        accent: coverAccent,
        // 小说简介普遍更长,收起时给到 10 行(漫画/番剧 4 行)。
        collapsedLines: 10,
        expandThreshold: 140,
        textKey: const Key('novel-detail-description'),
        expanded: _descriptionExpanded,
        onToggle: () =>
            setState(() => _descriptionExpanded = !_descriptionExpanded),
      );

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
                      color: Color.lerp(p.textPrimary, coverAccent, 0.4),
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
        if (_chapters.isEmpty && _chaptersLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_chapters.isEmpty)
          Expanded(
            child: EmptyState(
              title: _chaptersError != null
                  ? context.l10n.novel_loadFailed('$_chaptersError')
                  : context.l10n.novel_noChapters,
              action: _chaptersError == null
                  ? null
                  : TextButton.icon(
                      key: const Key('novel-directory-retry'),
                      onPressed: _retryChapters,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(context.l10n.retry),
                    ),
            ),
          )
        else ...[
          Expanded(
            child: ScrollablePositionedList.builder(
              // 键里不放章节数:目录是边拉边显示的,每来一页都换键会把
              // 列表重建一次、滚动位置弹回顶部。
              key: ValueKey(
                'novel-directory-${_meta.id}-${_novel.id}-$activeIndex',
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
          if (_chaptersLoading)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_chaptersError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.novel_loadFailed('$_chaptersError'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textMuted, fontSize: 11.5),
                    ),
                  ),
                  TextButton(
                    key: const Key('novel-directory-retry'),
                    onPressed: _retryChapters,
                    child: Text(context.l10n.retry),
                  ),
                ],
              ),
            ),
        ],
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
