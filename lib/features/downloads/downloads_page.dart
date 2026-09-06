import 'package:flutter/material.dart';

import '../../app/anime_download_store.dart';
import '../../app/download_store.dart';
import '../../app/download_coordinator_scope.dart';
import '../../app/theme/app_colors.dart';
import '../../core/downloads/content_download_task.dart';
import '../../core/downloads/download_coordinator.dart';
import '../../core/downloads/download_failure.dart';
import '../../core/downloads/download_task.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/cover_hero.dart';
import '../common/transitions.dart';
import '../anime/anime_downloads_view.dart';
import '../detail/detail_page.dart';
import '../library/manga_cover.dart';
import '../novel/novel_downloads_view.dart';
import 'download_kind_switch.dart';

export 'download_kind_switch.dart';

/// 下载:已下载漫画(按本地分组),点进详情离线读,可删除。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  DownloadKind _kind = DownloadKind.manga;
  DownloadViewMode _mode = DownloadViewMode.active;

  @override
  Widget build(BuildContext context) {
    if (_mode == DownloadViewMode.active) {
      return _ActiveDownloadsPage(
        kind: _kind,
        onKindChanged: (value) => setState(() => _kind = value),
        onModeChanged: (value) => setState(() => _mode = value),
      );
    }
    return switch (_kind) {
      DownloadKind.anime => _AnimeDownloadsPage(
          onKindChanged: (value) => setState(() => _kind = value),
          onModeChanged: (value) => setState(() => _mode = value),
        ),
      DownloadKind.manga => _MangaDownloadsPage(
          onKindChanged: (value) => setState(() => _kind = value),
          onModeChanged: (value) => setState(() => _mode = value),
        ),
      DownloadKind.novel => _NovelDownloadsPage(
          onKindChanged: (value) => setState(() => _kind = value),
          onModeChanged: (value) => setState(() => _mode = value),
        ),
    };
  }
}

class _ActiveDownloadsPage extends StatelessWidget {
  const _ActiveDownloadsPage({
    required this.kind,
    required this.onKindChanged,
    required this.onModeChanged,
  });

  final DownloadKind kind;
  final ValueChanged<DownloadKind> onKindChanged;
  final ValueChanged<DownloadViewMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final coordinator = DownloadCoordinatorScope.of(context);
    final tasks = coordinator.tasks
        .where((task) =>
            task.kind == _contentKind(kind) &&
            task.state != DownloadTaskState.completed)
        .toList(growable: false);
    return _DownloadScaffold(
      kind: kind,
      mode: DownloadViewMode.active,
      onKindChanged: onKindChanged,
      onModeChanged: onModeChanged,
      child: tasks.isEmpty
          ? EmptyState(
              icon: Icons.downloading_rounded,
              iconSize: 48,
              title: context.l10n.download_active,
              titleSize: 16,
              dense: true,
              message: context.l10n.dl_emptyHint,
            )
          : AppScrollView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              children: [
                for (final task in tasks)
                  _ActiveDownloadTile(
                    task: task,
                    coordinator: coordinator,
                  ),
              ],
            ),
    );
  }
}

class _ActiveDownloadTile extends StatefulWidget {
  const _ActiveDownloadTile({required this.task, required this.coordinator});

  final DownloadTask task;
  final DownloadCoordinator coordinator;

  @override
  State<_ActiveDownloadTile> createState() => _ActiveDownloadTileState();
}

class _ActiveDownloadTileState extends State<_ActiveDownloadTile> {
  bool _detailExpanded = false;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final coordinator = widget.coordinator;
    final p = context.palette;
    final determinate = task.totalBytes > 0;
    final detail = task.state == DownloadTaskState.failed
        ? (task.failure?.detail.trim() ?? '')
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        radius: 8,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_kindIcon(task.kind), color: p.accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        task.itemTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textMuted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                _TaskAction(task: task, coordinator: coordinator),
                IconButton(
                  tooltip: context.l10n.cancel,
                  onPressed: () => _cancel(context),
                  icon: Icon(Icons.close_rounded, color: p.textMuted, size: 19),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: determinate ? task.progress : null,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 6),
            _StatusLine(
              text: _statusText(context, task),
              failed: task.state == DownloadTaskState.failed,
              // 真实错误只在用户主动展开时露出:平时一行状态,排查时能看全。
              detail: _detailExpanded ? detail : null,
              onToggleDetail: detail.isEmpty
                  ? null
                  : () => setState(() => _detailExpanded = !_detailExpanded),
            ),
          ],
        ),
      ),
    );
  }

  /// 撤掉一条进行中的任务。
  ///
  /// 协调器的 `remove()` 只删任务记录,不回调执行器 —— 番剧任务半路取消时,已经落盘
  /// 的 `segment-*.bin` 和包目录会一直留着。番剧走 store 的 delete,让它顺手把目录清掉。
  Future<void> _cancel(BuildContext context) async {
    if (task.kind == DownloadContentKind.anime) {
      final store = AnimeDownloadScope.maybeRead(context);
      if (store != null) {
        final request = ContentDownloadRequest.fromTask(task);
        await store.delete(
          request.sourceId,
          request.contentId,
          request.chapterId,
          coordinator: coordinator,
        );
        return;
      }
    }
    await coordinator.remove(task.id);
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.text,
    required this.failed,
    required this.detail,
    required this.onToggleDetail,
  });

  final String text;
  final bool failed;
  final String? detail;
  final VoidCallback? onToggleDetail;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final expanded = detail != null;
    final label = Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: failed ? p.statusFail : p.textMuted,
        fontSize: 11,
      ),
    );
    if (onToggleDetail == null) {
      return Align(alignment: Alignment.centerLeft, child: label);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggleDetail,
          child: Row(
            children: [
              Flexible(child: label),
              const SizedBox(width: 4),
              Tooltip(
                message: context.l10n.download_failureDetail,
                child: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: p.textMuted,
                ),
              ),
            ],
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(
              detail!,
              style: TextStyle(color: p.textMuted, fontSize: 10.5),
            ),
          ),
      ],
    );
  }
}

class _TaskAction extends StatelessWidget {
  const _TaskAction({required this.task, required this.coordinator});

  final DownloadTask task;
  final DownloadCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return switch (task.state) {
      DownloadTaskState.paused => IconButton(
          tooltip: context.l10n.download_resume,
          onPressed: () => coordinator.resume(task.id),
          icon: const Icon(Icons.play_arrow_rounded),
        ),
      DownloadTaskState.failed || DownloadTaskState.cancelled => IconButton(
          tooltip: context.l10n.retry,
          onPressed: () => coordinator.retry(task.id),
          icon: const Icon(Icons.refresh_rounded),
        ),
      DownloadTaskState.resolving ||
      DownloadTaskState.queued ||
      DownloadTaskState.running ||
      DownloadTaskState.verifying =>
        IconButton(
          tooltip: context.l10n.download_pause,
          onPressed: () => coordinator.pause(task.id),
          icon: const Icon(Icons.pause_rounded),
        ),
      DownloadTaskState.completed => const SizedBox.shrink(),
    };
  }
}

class _AnimeDownloadsPage extends StatelessWidget {
  const _AnimeDownloadsPage({
    required this.onKindChanged,
    required this.onModeChanged,
  });

  final ValueChanged<DownloadKind> onKindChanged;
  final ValueChanged<DownloadViewMode> onModeChanged;

  @override
  Widget build(BuildContext context) => _DownloadScaffold(
        kind: DownloadKind.anime,
        mode: DownloadViewMode.completed,
        onKindChanged: onKindChanged,
        onModeChanged: onModeChanged,
        child: const AnimeDownloadsView(),
      );
}

class _NovelDownloadsPage extends StatelessWidget {
  const _NovelDownloadsPage({
    required this.onKindChanged,
    required this.onModeChanged,
  });

  final ValueChanged<DownloadKind> onKindChanged;
  final ValueChanged<DownloadViewMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: Text(
          context.l10n.navDownloads,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
        ),
        actions: [
          DownloadViewModeSwitch(
            selected: DownloadViewMode.completed,
            onSelected: onModeChanged,
          ),
          const SizedBox(width: 8),
          DownloadKindSwitch(
            selected: DownloadKind.novel,
            onSelected: onKindChanged,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: EntranceSlide(
        begin: const Offset(0, 0.06),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: const NovelDownloadsView(),
        ),
      ),
    );
  }
}

class _MangaDownloadsPage extends StatelessWidget {
  const _MangaDownloadsPage({
    required this.onKindChanged,
    required this.onModeChanged,
  });

  final ValueChanged<DownloadKind> onKindChanged;
  final ValueChanged<DownloadViewMode> onModeChanged;

  SourceMeta? _metaById(String id) {
    for (final s in registeredSources) {
      if (s.id == id) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dl = DownloadScope.of(context);
    final groups = dl.byManga;
    final keys = groups.keys.toList()
      ..sort(
          (a, b) => groups[b]!.first.doneAt.compareTo(groups[a]!.first.doneAt));

    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: Text(context.l10n.navDownloads,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          DownloadViewModeSwitch(
            selected: DownloadViewMode.completed,
            onSelected: onModeChanged,
          ),
          const SizedBox(width: 8),
          DownloadKindSwitch(
            selected: DownloadKind.manga,
            onSelected: onKindChanged,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: EntranceSlide(
        begin: const Offset(0, 0.06),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: keys.isEmpty
              ? _empty(context, p, dl)
              : AppScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                  children: [
                    if (dl.activeCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: p.accent),
                            ),
                            const SizedBox(width: 8),
                            Text(context.l10n.dl_downloadingN(dl.activeCount),
                                style: TextStyle(
                                    color: p.textMuted, fontSize: 12)),
                          ],
                        ),
                      ),
                    for (final k in keys)
                      _mangaTile(context, p, dl, groups[k]!),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _mangaTile(BuildContext context, AppPalette p, DownloadStore dl,
      List<DownloadedChapter> chapters) {
    final first = chapters.first;
    final meta = _metaById(first.sourceId);
    final manga = Manga(
        id: first.mangaId, title: first.mangaTitle, cover: first.mangaCover);
    final tag = meta == null
        ? null
        : coverHeroTag(CoverHeroScope.downloads,
            sourceId: meta.id, itemId: manga.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        radius: 12,
        padding: const EdgeInsets.all(10),
        onTap: meta == null
            ? null
            : () => pushPage(context, DetailPage(manga: manga, meta: meta, heroTag: tag)),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: MangaCover(
                manga: manga,
                headers: meta != null ? imageHeadersOf(meta) : const {},
                radius: 8,
                heroTag: tag,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(first.mangaTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: p.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5)),
                  const SizedBox(height: 3),
                  Text(
                      '${meta?.name ?? first.sourceId} · ${context.l10n.dl_chaptersDownloaded(chapters.length)}',
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ],
              ),
            ),
            IconButton(
              tooltip: context.l10n.delete,
              onPressed: () =>
                  _confirmDelete(context, dl, first, chapters.length),
              icon: Icon(Icons.delete_outline_rounded,
                  color: p.textMuted, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, DownloadStore dl,
      DownloadedChapter m, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.dl_deleteTitle),
        content: Text(context.l10n.dl_deleteConfirm(m.mangaTitle, count)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l10n.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(context.l10n.delete)),
        ],
      ),
    );
    if (ok == true) await dl.deleteManga(m.sourceId, m.mangaId);
  }

  Widget _empty(BuildContext context, AppPalette p, DownloadStore dl) =>
      EmptyState(
        icon: Icons.download_rounded,
        iconSize: 48,
        title: context.l10n.dl_emptyTitle,
        titleSize: 16,
        dense: true,
        message: dl.activeCount > 0
            ? context.l10n.dl_downloadingN(dl.activeCount)
            : context.l10n.dl_emptyHint,
      );
}

class _DownloadScaffold extends StatelessWidget {
  const _DownloadScaffold({
    required this.kind,
    required this.mode,
    required this.onKindChanged,
    required this.onModeChanged,
    required this.child,
  });

  final DownloadKind kind;
  final DownloadViewMode mode;
  final ValueChanged<DownloadKind> onKindChanged;
  final ValueChanged<DownloadViewMode> onModeChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: Text(
          context.l10n.navDownloads,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
        ),
        actions: [
          DownloadViewModeSwitch(selected: mode, onSelected: onModeChanged),
          const SizedBox(width: 8),
          DownloadKindSwitch(selected: kind, onSelected: onKindChanged),
          const SizedBox(width: 8),
        ],
      ),
      body: EntranceSlide(
        begin: const Offset(0, 0.06),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: child,
        ),
      ),
    );
  }
}

DownloadContentKind _contentKind(DownloadKind kind) => switch (kind) {
      DownloadKind.anime => DownloadContentKind.anime,
      DownloadKind.manga => DownloadContentKind.manga,
      DownloadKind.novel => DownloadContentKind.novel,
    };

IconData _kindIcon(DownloadContentKind kind) => switch (kind) {
      DownloadContentKind.anime => Icons.movie_outlined,
      DownloadContentKind.manga => Icons.photo_library_outlined,
      DownloadContentKind.novel => Icons.menu_book_outlined,
      DownloadContentKind.appUpdate => Icons.system_update_alt_rounded,
    };

String _statusText(BuildContext context, DownloadTask task) {
  return switch (task.state) {
    DownloadTaskState.paused => _pauseText(context, task.pauseReason),
    DownloadTaskState.failed => _failureText(context, task.failure?.code),
    DownloadTaskState.cancelled => context.l10n.download_failureCancelled,
    DownloadTaskState.resolving ||
    DownloadTaskState.queued ||
    DownloadTaskState.running ||
    DownloadTaskState.verifying =>
      task.totalBytes > 0
          ? context.l10n.update_downloadingProgress(
              (task.progress * 100).round(),
            )
          : context.l10n.download_active,
    DownloadTaskState.completed => context.l10n.download_completed,
  };
}

/// 失败文案按错误码取 l10n —— core 层只记码,四种语言各自成话。
String _failureText(BuildContext context, DownloadFailureCode? code) {
  final l10n = context.l10n;
  return switch (code) {
    DownloadFailureCode.network => l10n.download_failureNetwork,
    DownloadFailureCode.authenticationRequired => l10n.download_failureAuth,
    DownloadFailureCode.sourceRefreshRequired =>
      l10n.download_failureSourceRefresh,
    DownloadFailureCode.resourceMissing => l10n.download_failureMissing,
    DownloadFailureCode.insufficientStorage => l10n.download_failureStorageFull,
    DownloadFailureCode.storageUnavailable =>
      l10n.download_failureStorageUnavailable,
    DownloadFailureCode.unsafePath => l10n.download_failureUnsafePath,
    DownloadFailureCode.corruptResource => l10n.download_failureCorrupt,
    DownloadFailureCode.unsupportedDrm => l10n.download_failureDrm,
    DownloadFailureCode.cancelled => l10n.download_failureCancelled,
    DownloadFailureCode.unknown || null => l10n.download_failureUnknown,
  };
}

/// 暂停原因本来就存在任务上,一律显示「暂停」等于把它扔了 ——
/// 用户看不出是自己点的、还是在等 Wi-Fi / 等电 / 等空间。
String _pauseText(BuildContext context, DownloadPauseReason? reason) {
  final l10n = context.l10n;
  return switch (reason) {
    DownloadPauseReason.wifi => l10n.download_pausedWifi,
    DownloadPauseReason.roaming => l10n.download_pausedRoaming,
    DownloadPauseReason.battery => l10n.download_pausedBattery,
    DownloadPauseReason.storage => l10n.download_pausedStorage,
    DownloadPauseReason.auth => l10n.download_pausedAuth,
    DownloadPauseReason.sourceRefresh => l10n.download_pausedSourceRefresh,
    DownloadPauseReason.system => l10n.download_pausedSystem,
    DownloadPauseReason.externalStorage =>
      l10n.download_pausedExternalStorage,
    DownloadPauseReason.user || null => l10n.download_pausedUser,
  };
}
