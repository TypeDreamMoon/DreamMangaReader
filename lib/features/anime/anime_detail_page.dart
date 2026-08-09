import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/anime_download_store.dart';
import '../../app/anime_library_store.dart';
import '../../app/download_coordinator_scope.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/bangumi/bangumi_api.dart';
import '../../core/downloads/content_download_task.dart';
import '../../core/downloads/download_task.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/author_match.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/bangumi_card.dart';
import '../common/transitions.dart';
import '../detail/author_works_page.dart';
import '../detail/bangumi_search_sheet.dart';
import '../common/detail_cover_tint.dart';
import '../library/manga_cover.dart';
import 'anime_player_page.dart';

typedef AnimeBangumiLookup = Future<BangumiInfo?> Function(String title);

/// 番剧详情:与漫画/小说详情页同一套骨架 —— 沉浸式封面头 + 主操作行 + Bangumi 卡 +
/// 简介卡 + 分集网格,宽屏左右分栏。点某集 → [AnimePlayerPage] 播放。
/// 番剧沿用漫画契约:getMangaDetail(简介/封面)、getChapters(=分集)。
class AnimeDetailPage extends StatefulWidget {
  const AnimeDetailPage({
    super.key,
    required this.meta,
    required this.anime,
    this.heroTag,
    this.sourceBuilder = buildSource,
    this.bangumiLookup = _defaultBangumiLookup,
  });

  final SourceMeta meta;
  final Manga anime; // 列表卡带来的 id/title/cover

  /// 非空时封面用 Hero 从点击处飞入(须与来源封面同 tag)。
  final Object? heroTag;
  final MangaSource Function(SourceMeta meta) sourceBuilder;
  final AnimeBangumiLookup bangumiLookup;

  @override
  State<AnimeDetailPage> createState() => _AnimeDetailPageState();
}

class _AnimeDetailPageState extends State<AnimeDetailPage>
    with DetailCoverTint<AnimeDetailPage> {
  late final MangaSource _source = widget.sourceBuilder(widget.meta);
  Manga? _detail;
  List<Chapter> _episodes = const [];
  bool _loading = true;
  String? _error;

  // Bangumi(bgm.tv 番剧条目)评分。
  BangumiInfo? _bgm;
  bool _bgmLoading = true;
  bool _descExpanded = false;

  Manga get _display => _detail ?? widget.anime;
  Map<String, String> get _imgHeaders => imageHeadersOf(widget.meta);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final id = widget.anime.id;
      final detail = await _source.getMangaDetail(id);
      final eps = await _source.getChapters(id);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _episodes = eps.items;
        _loading = false;
      });
      unawaited(updateCoverTint(_display.cover, _imgHeaders));
      _loadBangumi(); // 详情就绪后匹配 Bangumi 番剧条目
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  String get _bgmTitle => (_detail?.title.isNotEmpty ?? false)
      ? _detail!.title
      : widget.anime.title;
  String get _bgmKey => '${widget.meta.id}:${widget.anime.id}';

  /// 匹配 Bangumi:有手动绑定只认它(失败不回退自动匹配),否则按标题在**动画**类目
  /// (type=2)自动置信匹配。失败静默留空。
  Future<void> _loadBangumi() async {
    final bound = LibraryScope.read(context).bangumiBindingFor(_bgmKey);
    final info = bound != null
        ? await BangumiApi.fromId(bound)
        : await widget.bangumiLookup(_bgmTitle);
    if (!mounted) return;
    setState(() {
      _bgm = info;
      _bgmLoading = false;
    });
  }

  /// 手动搜索 Bangumi 番剧条目并绑定(自动匹配不准/没匹配到时用)。
  Future<void> _openBangumiSearch() async {
    final picked = await showAppSheet<BangumiCandidate>(
      context,
      title: '搜索 Bangumi',
      showCloseButton: true,
      resizeForKeyboard: true,
      heightFactor: 0.7,
      body: (ctx, setSheet) =>
          BangumiSearchSheet(initialQuery: _bgmTitle, type: 2),
    );
    if (picked == null || !mounted) return;
    setState(() => _bgmLoading = true);
    final info = await BangumiApi.fromId(picked.id);
    if (!mounted) return;
    if (info == null) {
      setState(() => _bgmLoading = false);
      showAppNotify(context, '加载条目失败', kind: AppNotifyKind.error);
      return;
    }
    LibraryScope.read(context).setBangumiBinding(_bgmKey, picked.id);
    setState(() {
      _bgm = info;
      _bgmLoading = false;
    });
  }

  void _play(int index, {Duration position = Duration.zero}) =>
      Navigator.of(context).push(appRoute(AnimePlayerPage(
        meta: widget.meta,
        animeId: widget.anime.id,
        animeTitle: _title,
        episodes: _episodes,
        index: index,
        initialPosition: position,
      )));

  String _downloadTaskId(Chapter episode) => contentDownloadTaskId(
        DownloadContentKind.anime,
        widget.meta.id,
        widget.anime.id,
        episode.id,
      );

  Future<void> _queueDownload(Chapter episode) async {
    final downloads = AnimeDownloadScope.read(context);
    if (downloads.isDownloaded(widget.meta.id, widget.anime.id, episode.id)) {
      return;
    }
    final coordinator = DownloadCoordinatorScope.maybeRead(context);
    if (coordinator == null) return;
    final taskId = _downloadTaskId(episode);
    final existing = coordinator.task(taskId);
    if (existing == null) {
      await coordinator.enqueue(ContentDownloadTask.anime(
        sourceId: widget.meta.id,
        contentId: widget.anime.id,
        contentTitle: _detail?.title ?? widget.anime.title,
        chapterId: episode.id,
        chapterTitle: episode.name,
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
    final downloads = AnimeDownloadScope.read(context);
    final coordinator = DownloadCoordinatorScope.maybeRead(context);
    if (coordinator == null) return;
    final pending = _episodes.where((episode) {
      if (downloads.isDownloaded(
        widget.meta.id,
        widget.anime.id,
        episode.id,
      )) {
        return false;
      }
      final task = coordinator.task(_downloadTaskId(episode));
      return task == null ||
          task.state == DownloadTaskState.paused ||
          task.state == DownloadTaskState.failed ||
          task.state == DownloadTaskState.cancelled;
    }).toList(growable: false);
    if (pending.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载全部分集'),
        content: Text('将 $pending.length 集加入下载队列。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    for (final episode in pending) {
      await _queueDownload(episode);
    }
    if (mounted) {
      showAppNotify(context, '已加入 ${pending.length} 个下载任务',
          kind: AppNotifyKind.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    AnimeDownloadScope.of(context);
    DownloadCoordinatorScope.maybeOf(context);
    final p = context.palette;
    final acc = coverAccent;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            key: const Key('anime-download-all'),
            onPressed: !_loading && _episodes.isNotEmpty ? _downloadAll : null,
            tooltip: '下载全部分集',
            icon: const Icon(Icons.download_for_offline_rounded),
          ),
          const SizedBox(width: 4),
        ],
        // 与漫画详情同款:模糊身后封面 + 顶部渐深遮罩,任何封面上图标都清晰。
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
          ? _errorView(p)
          : DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [acc.withValues(alpha: 0.16), Colors.transparent],
                  stops: const [0.0, 0.55],
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth >= 760
                    ? _wideBody(p)
                    : _narrowBody(p),
              ),
            ),
    );
  }

  /// 竖屏:信息 + 分集单列纵向滚动。
  Widget _narrowBody(AppPalette p) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: AppScrollView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _hero(p),
              _cta(p),
              _bangumiCard(),
              _synopsis(p),
              _episodeSection(p),
            ],
          ),
        ),
      );

  /// 横屏/桌面:左列信息(独立滚动),右列分集(独立滚动)—— 与漫画详情同构。
  Widget _wideBody(AppPalette p) {
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
                    _cta(p),
                    _bangumiCard(),
                    _synopsis(p),
                  ],
                ),
              ),
            ),
            VerticalDivider(width: 1, thickness: 1, color: p.line),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(top: topInset, bottom: 28),
                child: _episodeSection(p),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(AppPalette p) {
    final anime = _display;
    final grad = coverGradient(widget.anime.id);
    final cover = anime.cover;
    final acc = coverAccent;
    final gradTop = coverPalette?.primary ?? grad.first;
    final gradBot = coverPalette?.secondary ?? grad.last;
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
                    manga: anime,
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
                      AppPill(
                        text: widget.meta.name,
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
                        _title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                      if (anime.authors.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        _authorLine(p, anime.authors, acc),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          AppPill.accent(_statusText(anime.status), acc),
                          for (final genre in anime.genres.take(6))
                            AppPill.outlined(genre, p),
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

  String get _title => (_detail?.title.isNotEmpty ?? false)
      ? _detail!.title
      : widget.anime.title;

  Widget _authorLine(AppPalette p, List<String> authors, Color accent) {
    final names = AuthorMatch.expand(authors);
    if (names.isEmpty) {
      return Text(
        context.l10n.detail_authorPrefix(authors.join('、')),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.textMuted, fontSize: 12),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(context.l10n.detail_authorPrefix('').trim(),
            style: TextStyle(color: p.textMuted, fontSize: 12)),
        for (final name in names)
          InkWell(
            key: Key('anime-author-$name'),
            onTap: () => Navigator.of(context).push(appRoute(AuthorWorksPage(
              author: name,
              meta: widget.meta,
              kind: 'anime',
              excludeMangaId: widget.anime.id,
              onOpen: (context, meta, anime) => Navigator.of(context).push(
                appRoute(AnimeDetailPage(meta: meta, anime: anime)),
              ),
            ))),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: Text(
                name,
                style: TextStyle(
                  color: Color.lerp(accent, p.textPrimary, .25),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: accent.withValues(alpha: .5),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _statusText(MangaStatus status) => switch (status) {
        MangaStatus.ongoing => context.l10n.detail_statusOngoing,
        MangaStatus.completed => context.l10n.detail_statusCompleted,
        MangaStatus.hiatus => context.l10n.detail_statusHiatus,
        MangaStatus.cancelled => context.l10n.detail_statusCancelled,
        MangaStatus.unknown => context.l10n.detail_statusUnknown,
      };


  /// 主操作行:播放 / 继续观看 + 收藏 + 下载全部 + 浏览器打开。
  Widget _cta(AppPalette p) {
    final library = AnimeLibraryScope.maybeOf(context);
    final history = library?.historyFor(widget.meta.id, widget.anime.id);
    final resumeIndex = history == null
        ? -1
        : _episodes.indexWhere((episode) => episode.id == history.episodeId);
    final canPlay = !_loading && _episodes.isNotEmpty;
    final resume = canPlay && resumeIndex >= 0;
    final acc = coverAccent;
    final accOn = coverPalette?.onPrimary ?? p.onAccent;
    final url = _display.url;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              key: const Key('anime-play'),
              onPressed: canPlay
                  ? () => _play(resume ? resumeIndex : 0,
                      position: resume
                          ? Duration(seconds: history!.positionSeconds)
                          : Duration.zero)
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: acc,
                foregroundColor: accOn,
                minimumSize: const Size.fromHeight(46),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                      resume
                          ? Icons.play_circle_fill_rounded
                          : Icons.play_arrow_rounded,
                      size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      resume
                          ? context.l10n
                              .detail_continueChapter(history!.episodeName)
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
          if (library != null) ...[
            const SizedBox(width: 10),
            _favoriteButton(p, library, acc),
          ],
          const SizedBox(width: 10),
          AppIconButton(
            icon: Icons.download_rounded,
            accent: acc,
            tooltip: context.l10n.detail_downloadAll,
            onTap: canPlay ? _downloadAll : null,
          ),
          if (url != null && url.isNotEmpty) ...[
            const SizedBox(width: 10),
            AppIconButton(
                icon: Icons.open_in_browser_rounded,
                accent: acc,
                tooltip: context.l10n.detail_openInBrowser,
                onTap: () => _openInBrowser(url)),
          ],
        ],
      ),
    );
  }

  Widget _favoriteButton(AppPalette p, AnimeLibraryStore library, Color acc) {
    final favorite = library.isFavorite(widget.meta.id, widget.anime.id);
    return AppIconButton(
      icon: favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      active: favorite,
      accent: acc,
      buttonKey: const Key('anime-favorite'),
      tooltip: favorite
          ? context.l10n.detail_removeFavorite
          : context.l10n.detail_addFavorite,
      onTap: () => library.toggleFavorite(AnimeFavoriteEntry(
        sourceId: widget.meta.id,
        animeId: widget.anime.id,
        title: _display.title,
        cover: _display.cover,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      )),
    );
  }


  Future<void> _openInBrowser(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showAppNotify(context, context.l10n.detail_cannotOpenLink(raw),
          kind: AppNotifyKind.error);
    }
  }

  Widget _bangumiCard() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: BangumiCard(
          loading: _bgmLoading,
          info: _bgm,
          onRematch: _openBangumiSearch,
        ),
      );

  /// 简介卡:源没给就退回 Bangumi 的简介,长文可展开(与漫画详情一致)。
  Widget _synopsis(AppPalette p) {
    var description = (_display.description ?? '').trim();
    var fromBangumi = false;
    if (description.isEmpty) {
      description = (_bgm?.summary ?? '').trim();
      fromBangumi = description.isNotEmpty;
    }
    if (description.isEmpty) return const SizedBox.shrink();
    final acc = coverAccent;
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(context.l10n.detail_synopsis,
                    style: TextStyle(
                        color: acc,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0)),
                if (fromBangumi) ...[
                  const SizedBox(width: 6),
                  Text(context.l10n.detail_fromBangumi,
                      style: TextStyle(color: p.textMuted, fontSize: 10.5)),
                ],
              ],
            ),
            const SizedBox(height: 8),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: Text(
                description,
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
            if (description.length > 90) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(() => _descExpanded = !_descExpanded),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                        _descExpanded
                            ? context.l10n.detail_collapse
                            : context.l10n.detail_expandAll,
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

  Widget _episodeSection(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSectionHeading('分集', fontSize: 18),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_episodes.isEmpty)
              const EmptyState(
                title: '没有分集',
                padding: EdgeInsets.symmetric(vertical: 30, horizontal: 24),
              )
            else
              _episodeGrid(p),
          ],
        ),
      );

  Widget _episodeGrid(AppPalette p) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < _episodes.length; i++)
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 82, maxWidth: 220),
              child: AppCard(
                onTap: () => _play(i),
                radius: context.radius,
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _epLabel(_episodes[i], i),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _downloadControl(p, _episodes[i]),
                  ],
                ),
              ),
            ),
        ],
      );

  Widget _downloadControl(AppPalette p, Chapter episode) {
    final downloads = AnimeDownloadScope.read(context);
    if (downloads.isDownloaded(widget.meta.id, widget.anime.id, episode.id)) {
      return Icon(Icons.download_done_rounded, size: 18, color: p.accent);
    }
    final task = DownloadCoordinatorScope.maybeRead(context)
        ?.task(_downloadTaskId(episode));
    if (task?.state == DownloadTaskState.completed) {
      return Icon(Icons.download_done_rounded, size: 18, color: p.accent);
    }
    final active = task != null &&
        (task.state == DownloadTaskState.resolving ||
            task.state == DownloadTaskState.queued ||
            task.state == DownloadTaskState.running ||
            task.state == DownloadTaskState.verifying);
    if (active) {
      return SizedBox(
        width: 32,
        height: 32,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: CircularProgressIndicator(
            value: task.progress > 0 ? task.progress : null,
            strokeWidth: 2,
            color: p.accent,
          ),
        ),
      );
    }
    final failed = task?.state == DownloadTaskState.failed ||
        task?.state == DownloadTaskState.cancelled;
    return IconButton(
      key: Key('anime-download-${episode.id}'),
      onPressed: () => _queueDownload(episode),
      tooltip: failed ? '重试下载' : '下载本集',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      icon: Icon(
        failed ? Icons.refresh_rounded : Icons.download_rounded,
        size: 18,
        color: failed ? p.statusFail : p.textMuted,
      ),
    );
  }

  // 集标签:优先数字集号,否则用名字(截断)。
  String _epLabel(Chapter c, int i) {
    final n = c.number;
    if (n != null) {
      return n == n.roundToDouble() ? '${n.toInt()}' : '$n';
    }
    final name = c.name.trim();
    return name.isEmpty ? '${i + 1}' : name;
  }

  Widget _errorView(AppPalette p) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 40, color: p.textMuted),
              const SizedBox(height: 12),
              Text('加载失败',
                  style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              SelectableText(_error ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textMuted, fontSize: 12)),
              const SizedBox(height: 14),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
}

Future<BangumiInfo?> _defaultBangumiLookup(String title) =>
    BangumiApi.lookup(title, type: 2);

class AnimeFavoriteAction extends StatelessWidget {
  const AnimeFavoriteAction({
    super.key,
    required this.meta,
    required this.anime,
  });

  final SourceMeta meta;
  final Manga anime;

  @override
  Widget build(BuildContext context) {
    final library = AnimeLibraryScope.of(context);
    final favorite = library.isFavorite(meta.id, anime.id);
    return IconButton(
      key: const Key('anime-favorite'),
      onPressed: () => library.toggleFavorite(AnimeFavoriteEntry(
        sourceId: meta.id,
        animeId: anime.id,
        title: anime.title,
        cover: anime.cover,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      )),
      tooltip:
          favorite ? context.l10n.animeUnfavorite : context.l10n.animeFavorite,
      icon: Icon(
        favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      ),
    );
  }
}
