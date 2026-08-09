import 'dart:async';
import 'dart:ui' show ImageFilter;

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
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/bangumi_card.dart';
import '../common/transitions.dart';
import '../detail/author_works_page.dart';
import '../detail/bangumi_search_sheet.dart';
import '../common/detail_body.dart';
import '../common/detail_cover_tint.dart';
import '../common/cross_source_sessions.dart';
import '../common/detail_cta.dart';
import '../common/detail_author_line.dart';
import '../detail/cross_source_sheet.dart';
import '../common/detail_hero.dart';
import '../common/detail_synopsis.dart';
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
      showAppNotify(context, context.l10n.anime_loadItemFailed, kind: AppNotifyKind.error);
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
        title: Text(context.l10n.anime_downloadAllEpisodes),
        content: Text('将 $pending.length 集加入下载队列。'),
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
    if (confirmed != true || !mounted) return;
    for (final episode in pending) {
      await _queueDownload(episode);
    }
    if (mounted) {
      showAppNotify(context, '已加入 ${pending.length} 个下载任务',
          kind: AppNotifyKind.success);
    }
  }

  /// 换源:在其它启用的**番剧**源里搜同名,选中后整页换到那个源。
  /// 漫画/小说早就有,番剧一直缺 —— 三家现在共用同一个弹层。
  Future<void> _changeSource() async {
    final store = LibraryScope.read(context);
    final candidates = [
      for (final s in registeredSources)
        if (s.kind == 'anime' &&
            s.id != widget.meta.id &&
            store.isSourceEnabled(s.id))
          s,
    ];
    final picked = await showAppSheet<CrossSourcePick>(
      context,
      title: context.l10n.detail_switchSource,
      showCloseButton: true,
      resizeForKeyboard: true,
      heightFactor: 0.7,
      body: (ctx, setSheet) => CrossSourceSheet(
        title: _display.title,
        sources: candidates,
        settings: store,
        sessionFactory: (meta) =>
            MangaCrossSourceSession(meta, builder: widget.sourceBuilder),
      ),
    );
    if (picked == null || !mounted) return;
    Navigator.of(context).pushReplacement(appRoute(AnimeDetailPage(
      meta: picked.meta,
      anime: picked.item.payload as Manga,
      sourceBuilder: widget.sourceBuilder,
      bangumiLookup: widget.bangumiLookup,
    )));
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
            key: const Key('anime-change-source'),
            tooltip: context.l10n.detail_switchSource,
            onPressed: _changeSource,
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
          IconButton(
            key: const Key('anime-download-all'),
            onPressed: !_loading && _episodes.isNotEmpty ? _downloadAll : null,
            tooltip: context.l10n.anime_downloadAllEpisodes,
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
              child: DetailBody(
                info: [_hero(p), _cta(p), _bangumiCard(), _synopsis(p)],
                listing: (_) => DetailListing.slivers(_episodeSlivers(p)),
              ),
            ),
    );
  }

  Widget _hero(AppPalette p) {
    final anime = _display;
    final acc = coverAccent;
    return DetailHero(
      gradientSeed: widget.anime.id,
      palette: coverPalette,
      accent: acc,
      cover: MangaCover(
        manga: anime,
        headers: _imgHeaders,
        radius: 12,
        heroTag: widget.heroTag,
      ),
      backdropUrl: anime.cover,
      backdropHeaders: _imgHeaders,
      sourceName: widget.meta.name,
      title: _title,
      statusText: _statusText(anime.status),
      genres: anime.genres,
      authorLine: anime.authors.isEmpty
          ? null
          : DetailAuthorLine(
              authors: anime.authors,
              accent: acc,
              keyPrefix: 'anime-author',
              onOpenAuthor: _openAuthorWorks,
            ),
    );
  }

  String get _title => (_detail?.title.isNotEmpty ?? false)
      ? _detail!.title
      : widget.anime.title;

  void _openAuthorWorks(String author) {
    Navigator.of(context).push(appRoute(AuthorWorksPage(
      author: author,
      meta: widget.meta,
      kind: 'anime',
      excludeMangaId: widget.anime.id,
      onOpen: (context, meta, anime, heroTag) => Navigator.of(context).push(
        appRoute(
            AnimeDetailPage(meta: meta, anime: anime, heroTag: heroTag)),
      ),
    )));
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
    final url = _display.url;
    return DetailCta(
      primaryKey: const Key('anime-play'),
      accent: acc,
      onAccent: coverPalette?.onPrimary ?? p.onAccent,
      resumed: resume,
      resumeLabel: history?.episodeName ?? '',
      onPrimary: canPlay
          ? () => _play(resume ? resumeIndex : 0,
              position: resume
                  ? Duration(seconds: history!.positionSeconds)
                  : Duration.zero)
          : null,
      actions: [
        if (library != null) _favoriteButton(p, library, acc),
        AppIconButton(
          icon: Icons.download_rounded,
          accent: acc,
          tooltip: context.l10n.detail_downloadAll,
          onTap: canPlay ? _downloadAll : null,
        ),
        if (url != null && url.isNotEmpty)
          AppIconButton(
            icon: Icons.open_in_browser_rounded,
            accent: acc,
            tooltip: context.l10n.detail_openInBrowser,
            onTap: () => _openInBrowser(url),
          ),
      ],
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
    final desc = resolveSynopsis(_display.description, _bgm?.summary);
    return DetailSynopsis(
      text: desc.text,
      accent: coverAccent,
      sourceNote:
          desc.fromFallback ? context.l10n.detail_fromBangumi : null,
      expanded: _descExpanded,
      onToggle: () => setState(() => _descExpanded = !_descExpanded),
    );
  }

  /// 分集列表。与漫画章节表 / 小说目录同一副长相:表头(带集数)+ 一列描边行。
  /// 原来是一排数字方块(Wrap 网格)—— 长番几百集时既难扫读也难点,而且集名根本放不下。
  ///
  /// 走惰性 sliver:上百集也只建可见行(和漫画章节表同一个理由)。
  List<Widget> _episodeSlivers(AppPalette p) {
    final acc = coverAccent;
    final header = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.anime_episodes,
                style: TextStyle(
                    // 与漫画/小说表头同款:标题色向封面主色偏一点,融进页面。
                    color: Color.lerp(p.textPrimary, acc, 0.4),
                    fontWeight: FontWeight.w700,
                    fontSize: 13),
              ),
            ),
            if (_episodes.isNotEmpty)
              Text(context.l10n.anime_episodesN(_episodes.length),
                  style: TextStyle(color: p.textMuted, fontSize: 12.5)),
          ],
        ),
      ),
    );
    if (_loading) {
      return [
        header,
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (_episodes.isEmpty) {
      return [
        header,
        SliverToBoxAdapter(
          child: EmptyState(
            title: context.l10n.anime_noEpisodes,
            padding:
                const EdgeInsets.symmetric(vertical: 30, horizontal: 24),
          ),
        ),
      ];
    }
    // 续播的那一集高亮(小说目录标当前章的同一处理)。
    final activeId = AnimeLibraryScope.maybeOf(context)
        ?.historyFor(widget.meta.id, widget.anime.id)
        ?.episodeId;
    return [
      header,
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.builder(
          itemCount: _episodes.length,
          itemBuilder: (context, index) => _episodeRow(p, index, activeId),
        ),
      ),
    ];
  }

  Widget _episodeRow(AppPalette p, int index, String? activeId) {
    final episode = _episodes[index];
    final active = episode.id == activeId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _play(index),
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
                child: Text(_epTitle(episode, index),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: active ? p.accentSoft : p.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5)),
              ),
              const SizedBox(width: 8),
              if (active) ...[
                Icon(Icons.play_circle_rounded, size: 15, color: p.accent),
                const SizedBox(width: 8),
              ],
              _downloadControl(p, episode),
            ],
          ),
        ),
      ),
    );
  }

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
      tooltip: failed
          ? context.l10n.anime_retryDownload
          : context.l10n.anime_downloadEpisode,
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

  /// 列表行的集名:优先源给的名字,没有才退回集号。
  /// (原来的方块网格是反过来的 —— 一个格子只放得下一个数字。)
  String _epTitle(Chapter c, int i) {
    final name = c.name.trim();
    if (name.isNotEmpty) return name;
    final n = c.number;
    if (n != null) return n == n.roundToDouble() ? '${n.toInt()}' : '$n';
    return '${i + 1}';
  }

  Widget _errorView(AppPalette p) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 40, color: p.textMuted),
              const SizedBox(height: 12),
              Text(context.l10n.loadFailed,
                  style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              SelectableText(_error ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textMuted, fontSize: 12)),
              const SizedBox(height: 14),
              FilledButton(onPressed: _load, child: Text(context.l10n.retry)),
            ],
          ),
        ),
      );
}

Future<BangumiInfo?> _defaultBangumiLookup(String title) =>
    BangumiApi.lookup(title, type: 2);
