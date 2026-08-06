import 'package:flutter/material.dart';

import '../../app/anime_download_store.dart';
import '../../app/anime_library_store.dart';
import '../../app/download_coordinator_scope.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/bangumi/bangumi_api.dart';
import '../../core/downloads/content_download_task.dart';
import '../../core/downloads/download_task.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/bangumi_card.dart';
import '../common/transitions.dart';
import '../detail/bangumi_search_sheet.dart';
import '../library/manga_cover.dart';
import 'anime_player_page.dart';

typedef AnimeBangumiLookup = Future<BangumiInfo?> Function(String title);

/// 番剧详情:封面 + 简介 + 分集网格。点某集 → [AnimePlayerPage] 播放。
/// 番剧沿用漫画契约:getMangaDetail(简介/封面)、getChapters(=分集)。
class AnimeDetailPage extends StatefulWidget {
  const AnimeDetailPage({
    super.key,
    required this.meta,
    required this.anime,
    this.sourceBuilder = buildSource,
    this.bangumiLookup = _defaultBangumiLookup,
  });

  final SourceMeta meta;
  final Manga anime; // 列表卡带来的 id/title/cover
  final MangaSource Function(SourceMeta meta) sourceBuilder;
  final AnimeBangumiLookup bangumiLookup;

  @override
  State<AnimeDetailPage> createState() => _AnimeDetailPageState();
}

class _AnimeDetailPageState extends State<AnimeDetailPage> {
  late final MangaSource _source = widget.sourceBuilder(widget.meta);
  Manga? _detail;
  List<Chapter> _episodes = const [];
  bool _loading = true;
  String? _error;

  // Bangumi(bgm.tv 番剧条目)评分。
  BangumiInfo? _bgm;
  bool _bgmLoading = true;

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

  void _play(int index) => Navigator.of(context).push(appRoute(AnimePlayerPage(
        meta: widget.meta,
        animeId: widget.anime.id,
        animeTitle: (_detail?.title.isNotEmpty ?? false)
            ? _detail!.title
            : widget.anime.title,
        episodes: _episodes,
        index: index,
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
    final title = (_detail?.title.isNotEmpty ?? false)
        ? _detail!.title
        : widget.anime.title;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        actions: [
          if (AnimeLibraryScope.maybeRead(context) != null)
            AnimeFavoriteAction(
              meta: widget.meta,
              anime: _detail ?? widget.anime,
            ),
          IconButton(
            key: const Key('anime-download-all'),
            onPressed: !_loading && _episodes.isNotEmpty ? _downloadAll : null,
            tooltip: '下载全部分集',
            icon: const Icon(Icons.download_for_offline_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _error != null
          ? _errorView(p)
          : AppScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _header(p, title),
                const SizedBox(height: 16),
                BangumiCard(
                  loading: _bgmLoading,
                  info: _bgm,
                  onRematch: _openBangumiSearch,
                ),
                const SizedBox(height: 20),
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
  }

  Widget _header(AppPalette p, String title) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: MangaCover(
              manga: _detail ?? widget.anime,
              headers: imageHeadersOf(widget.meta),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.25)),
                const SizedBox(height: 8),
                Text(widget.meta.name,
                    style: TextStyle(color: p.accentSoft, fontSize: 12)),
                const SizedBox(height: 10),
                if ((_detail?.description ?? '').isNotEmpty)
                  Text(_detail!.description!,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: p.textMuted, fontSize: 12.5, height: 1.5)),
              ],
            ),
          ),
        ],
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
      tooltip: favorite ? '取消收藏' : '收藏',
      icon: Icon(
        favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      ),
    );
  }
}
