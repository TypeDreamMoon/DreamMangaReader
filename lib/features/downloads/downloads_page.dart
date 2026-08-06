import 'package:flutter/material.dart';

import '../../app/download_store.dart';
import '../../app/download_coordinator_scope.dart';
import '../../app/theme/app_colors.dart';
import '../../core/downloads/download_coordinator.dart';
import '../../core/downloads/download_task.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/transitions.dart';
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

class _ActiveDownloadTile extends StatelessWidget {
  const _ActiveDownloadTile({required this.task, required this.coordinator});

  final DownloadTask task;
  final DownloadCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final determinate = task.totalBytes > 0;
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
                  onPressed: () => coordinator.remove(task.id),
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
            Text(
              _statusText(context, task),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: task.state == DownloadTaskState.failed
                    ? p.statusFail
                    : p.textMuted,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
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
        child: EmptyState(
          icon: Icons.movie_outlined,
          iconSize: 48,
          title: context.l10n.download_completed,
          titleSize: 16,
          dense: true,
          message: context.l10n.dl_emptyHint,
        ),
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
    final tag = meta == null ? null : 'dl:${meta.id}:${manga.id}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        radius: 12,
        padding: const EdgeInsets.all(10),
        onTap: meta == null
            ? null
            : () => Navigator.of(context).push(
                appRoute(DetailPage(manga: manga, meta: meta, heroTag: tag))),
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
    DownloadTaskState.paused => context.l10n.download_pause,
    DownloadTaskState.failed => task.failure?.message ?? context.l10n.retry,
    DownloadTaskState.cancelled => context.l10n.retry,
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
