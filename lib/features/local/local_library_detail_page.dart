import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/anime_library_store.dart';
import '../../app/local_media_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/local/local_models.dart';
import '../../core/platform/local_media_bridge.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import '../common/transitions.dart';
import 'local_library_actions.dart';
import 'local_player_page.dart';

/// 一个本地库的详情页:条目列表 + 继续观看 + 重新扫描 + 移除条目(规格 §8.2)。
///
/// 与番剧详情页的分工一样,这里只负责「挑哪一条、从哪儿开始播」;
/// 播放本身、进度记录、字幕都在 [LocalPlayerPage] 里。
///
/// 断点走 `AnimeLibraryStore`(`sourceId = 'local'`、`animeId = 库 id`),
/// 与番剧共用同一张历史表(规格 §5.4)。
class LocalLibraryDetailPage extends StatefulWidget {
  const LocalLibraryDetailPage({
    super.key,
    required this.libraryId,
    this.store,
    this.actions,
    this.bridge,
    this.playerDependencies,
  });

  final String libraryId;

  /// 测试注入;正常从 [LocalMediaScope] 取。
  final LocalMediaStore? store;

  /// 测试注入;正常按当前语言与平台就地构造。
  final LocalLibraryActions? actions;

  /// Android 的 fd 解析通道,透传给播放页。
  final LocalMediaBridge? bridge;

  /// 透传给 [LocalPlayerPage] 的播放注入点(测试用:真播放要原生库)。
  final LocalPlayerDependencies? playerDependencies;

  @override
  State<LocalLibraryDetailPage> createState() => _LocalLibraryDetailPageState();
}

class _LocalLibraryDetailPageState extends State<LocalLibraryDetailPage> {
  LocalMediaStore? _store;
  AnimeLibraryStore? _history;
  LocalLibraryActions? _actions;
  LocalMediaBridge? _bridge;
  bool _bootstrapped = false;
  bool _rescanning = false;

  /// Android 上授权失效过一次(播放前 `stat` 拿不到条目):显示「重新授权」。
  bool _authNeeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final l10n = context.l10n;
    _bridge = widget.bridge ?? LocalMediaBridge();
    _history = AnimeLibraryScope.maybeRead(context);
    if (_bootstrapped) return;
    _bootstrapped = true;
    _store = widget.store ?? LocalMediaScope.of(context);
    _actions = widget.actions ??
        LocalLibraryActions(
          store: _store!,
          l10n: l10n,
          bridge: _bridge,
          report: (message, kind) {
            if (!mounted) return;
            showAppNotify(context, message, kind: kind);
          },
        );
  }

  Future<void> _rescan(LocalLibrary library) async {
    final actions = _actions;
    if (actions == null || _rescanning) return;
    setState(() => _rescanning = true);
    try {
      await actions.rescan(library);
    } finally {
      if (mounted) setState(() => _rescanning = false);
    }
  }

  Future<void> _removeLibrary(LocalLibrary library) async {
    final l10n = context.l10n;
    final confirmed = await showAppConfirm(
      context,
      title: l10n.local_removeLibrary,
      message: l10n.local_removeLibraryConfirm,
      confirmLabel: l10n.local_removeLibrary,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final removed = await _actions?.removeLibrary(library) ?? false;
    if (!removed || !mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _removeItem(LocalMediaItem item) async {
    final store = _store;
    if (store == null) return;
    try {
      await store.removeItem(item.id);
    } on LocalMediaException catch (error) {
      if (!mounted) return;
      showAppNotify(context, error.message, kind: AppNotifyKind.error);
    }
  }

  /// 重新向系统要一次目录授权(Android)。
  ///
  /// SAF 的持久授权失效后,子文档 uri 不变,重新挑同一个目录就能把权限拿回来 ——
  /// 所以这里**不改索引**,只是把「不可用」的状态清掉再试一次。
  Future<void> _reauthorize() async {
    final actions = _actions;
    if (actions == null) return;
    try {
      final picked = await actions.picker.pickDirectory();
      if (picked == null) return;
      if (!mounted) return;
      setState(() => _authNeeded = false);
    } on Object {
      if (!mounted) return;
      showAppNotify(context, context.l10n.local_needAuth, kind: AppNotifyKind.warn);
    }
  }

  Future<void> _play(LocalMediaItem item, {Duration startAt = Duration.zero}) async {
    final store = _store;
    final library = store?.library(widget.libraryId);
    if (store == null || library == null) return;
    final items = store.items(widget.libraryId);
    final playable = [
      for (final entry in items)
        if (store.isAvailable(entry)) entry,
    ];
    final index = playable.indexWhere((entry) => entry.id == item.id);
    if (index < 0) {
      showAppNotify(context, context.l10n.local_fileMissing,
          kind: AppNotifyKind.warn);
      return;
    }
    // Android 上「索引里在、文件没了/授权没了」只有真去 stat 才知道(§9)。
    if (_bridge?.isAndroid ?? false) {
      LocalMediaEntry? probe;
      try {
        probe = await _bridge!.stat(item.location);
      } on Object {
        probe = null;
      }
      if (!mounted) return;
      if (probe == null) {
        setState(() => _authNeeded = true);
        showAppNotify(context, context.l10n.local_needAuth,
            kind: AppNotifyKind.warn);
        return;
      }
    }
    await pushPage(
      context,
      LocalPlayerPage(
        library: library,
        items: playable,
        initialIndex: index,
        initialPosition: startAt,
        bridge: widget.bridge,
        dependencies: widget.playerDependencies,
      ),
    );
  }

  /// 继续观看:历史里记的是 `episodeId`(条目 id),按 id 找回条目而不是信任下标。
  (LocalMediaItem, Duration)? _resumeTarget(LocalMediaStore store) {
    final entry = _history?.historyFor(LocalSource.id, widget.libraryId);
    if (entry == null) return null;
    final item = store.item(entry.episodeId);
    if (item == null || item.libraryId != widget.libraryId) return null;
    if (!store.isAvailable(item)) return null;
    final duration = entry.durationSeconds;
    final position = entry.positionSeconds;
    // 距片尾 10 秒内不算续播点(与播放会话同一规则,§5.4)。
    if (duration > 0 && position >= duration - 10) return null;
    if (position <= 0) return null;
    return (item, Duration(seconds: position));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final store = _store;
    if (store == null) return const SizedBox.shrink();
    final library = store.library(widget.libraryId);
    if (library == null) {
      // 库在别处被移除了(或者首次进入时 id 已失效):退回上一页。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    final items = store.items(widget.libraryId);
    final resume = _resumeTarget(store);
    final warning = store.loadWarning;

    return Scaffold(
      appBar: AppBar(
        title: Text(library.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (library.kind == LocalLibraryKind.folder)
            IconButton(
              tooltip: l10n.local_rescan,
              onPressed: _rescanning ? null : () => unawaited(_rescan(library)),
              icon: _rescanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          IconButton(
            tooltip: l10n.local_removeLibrary,
            onPressed: () => unawaited(_removeLibrary(library)),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: AppScrollView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: [
          if (warning != null) ...[
            AppCard(
              radius: 8,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: p.statusFail),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      warning,
                      style: TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (_authNeeded) ...[
            AppCard(
              radius: 8,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              child: Row(
                children: [
                  Icon(Icons.lock_outline_rounded, size: 18, color: p.statusWarn),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      l10n.local_needAuth,
                      style: TextStyle(color: p.textPrimary, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(_reauthorize()),
                    child: Text(l10n.local_authorize),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (resume != null) ...[
            AppCard(
              radius: 8,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.local_continueWatching,
                          style: TextStyle(
                            color: p.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          resume.$1.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: () =>
                        unawaited(_play(resume.$1, startAt: resume.$2)),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: Text(_durationLabel(resume.$2)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Icon(Icons.playlist_play_rounded, color: p.accent, size: 20),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  l10n.local_episodes,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                l10n.local_itemCount(items.length),
                style: TextStyle(color: p.textMuted, fontSize: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (items.isEmpty)
            EmptyState(
              icon: Icons.movie_outlined,
              iconSize: 44,
              title: l10n.local_emptyFolder,
              dense: true,
            )
          else
            for (var index = 0; index < items.length; index++)
              FadeSlideIn(
                delayMs: 25 * index.clamp(0, 8),
                child: _ItemCard(
                  index: index,
                  item: items[index],
                  available: store.isAvailable(items[index]),
                  onPlay: () => unawaited(_play(items[index])),
                  onRemove: () => unawaited(_removeItem(items[index])),
                ),
              ),
        ],
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.index,
    required this.item,
    required this.available,
    required this.onPlay,
    required this.onRemove,
  });

  final int index;
  final LocalMediaItem item;
  final bool available;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final meta = <String>[
      if (item.durationMs != null && item.durationMs! > 0)
        _durationLabel(Duration(milliseconds: item.durationMs!)),
      if (item.sizeBytes > 0) _sizeLabel(item.sizeBytes),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        radius: 8,
        onTap: available ? onPlay : null,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: available ? p.textMuted : p.textMuted.withValues(alpha: 0.5),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title.isEmpty ? l10n.local_unknownTitle : item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: available ? p.textPrimary : p.textMuted,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (!available)
                        _Badge(
                          text: l10n.local_fileMissing,
                          color: p.statusFail,
                        )
                      else if (item.lastPlayedAt != null)
                        _Badge(text: l10n.local_watched, color: p.accent),
                      if (!available || item.lastPlayedAt != null)
                        const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          meta.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.textMuted, fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: l10n.local_removeItem,
              icon: Icon(Icons.more_vert_rounded, size: 20, color: p.textMuted),
              onSelected: (_) => onRemove(),
              itemBuilder: (ctx) => [
                PopupMenuItem<String>(
                  value: 'remove',
                  child: Row(
                    children: [
                      Icon(Icons.playlist_remove_rounded,
                          size: 18, color: ctx.palette.textMuted),
                      const SizedBox(width: 8),
                      Text(l10n.local_removeItem),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w700),
        ),
      );
}

/// `h:mm:ss` / `mm:ss`。
String _durationLabel(Duration duration) {
  final total = duration.inSeconds;
  if (total <= 0) return '00:00';
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

/// 与番剧下载页同款的文件大小标签。
String _sizeLabel(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}
