import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/local_media_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/local/local_models.dart';
import '../../core/platform/local_media_bridge.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import '../common/transitions.dart';
import 'local_library_actions.dart';
import 'local_library_detail_page.dart';
import 'local_widgets.dart';

/// 本地播放的总入口页:本地库列表 + 「添加文件夹 / 添加文件」(规格 §8.1)。
///
/// 这一页只管库;条目、继续观看、重扫在 [LocalLibraryDetailPage] 里。
/// 挑位置与扫描的差异(Windows 的 file_picker/dart:io 与 Android 的 SAF 桥)
/// 全部封在 `LocalLibraryActions` 里,这一页两端完全同构。
class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    this.store,
    this.actions,
    this.bridge,
  });

  /// 测试注入;正常从 [LocalMediaScope] 取。
  final LocalMediaStore? store;

  /// 测试注入;正常按当前语言与平台就地构造。
  final LocalLibraryActions? actions;

  /// Android 的 SAF 桥;注入后 `LocalLibraryActions` 也会用它。
  final LocalMediaBridge? bridge;

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage>
    with LocalLibraryPageScaffold<LocalLibraryPage> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // store 与 actions 只解析一次;闸门、提示出口都在脚手架里。
    bootstrapLocalLibrary(
      store: widget.store,
      actions: widget.actions,
      bridge: widget.bridge,
    );
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
    await runLocalLibraryAction((actions) async {
      await actions.removeLibrary(library);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final store = localStore;
    final libraries = store?.libraries ?? const <LocalLibrary>[];
    final warning = store?.loadWarning;
    final total = store?.allItems.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.local_title),
        actions: [
          IconButton(
            tooltip: l10n.local_addFolder,
            onPressed: localBusy
                ? null
                : () => unawaited(runLocalLibraryAction((a) => a.addFolder())),
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: l10n.local_addFiles,
            onPressed: localBusy
                ? null
                : () => unawaited(runLocalLibraryAction((a) => a.addFiles())),
            icon: const Icon(Icons.video_library_outlined),
          ),
        ],
      ),
      body: AppScrollView(
        padding: kLocalLibraryPagePadding,
        children: [
          if (warning != null) ...[
            LocalNoticeCard(
              icon: Icons.error_outline_rounded,
              iconColor: p.statusFail,
              message: warning,
              messageStyle: TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 10),
          ],
          if (localBusy) ...[
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 9),
                Text(
                  l10n.local_scanning,
                  style: TextStyle(color: p.textMuted, fontSize: 12.5),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          if (libraries.isEmpty)
            EmptyState(
              icon: Icons.folder_open_outlined,
              iconSize: 48,
              title: l10n.local_emptyTitle,
              message: l10n.local_emptyHint,
              titleSize: 16,
              action: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: localBusy
                        ? null
                        : () => unawaited(runLocalLibraryAction((a) => a.addFolder())),
                    icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                    label: Text(l10n.local_addFolder),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: localBusy
                        ? null
                        : () => unawaited(runLocalLibraryAction((a) => a.addFiles())),
                    icon: const Icon(Icons.video_library_outlined, size: 18),
                    label: Text(l10n.local_addFiles),
                  ),
                ],
              ),
            )
          else ...[
            LocalSectionHeader(
              icon: Icons.video_settings_rounded,
              title: l10n.local_libraryTitle,
              trailing: l10n.local_itemCount(total),
            ),
            const SizedBox(height: 8),
            for (var index = 0; index < libraries.length; index++)
              FadeSlideIn(
                delayMs: 25 * index.clamp(0, 8),
                child: _LibraryCard(
                  library: libraries[index],
                  itemCount: store?.items(libraries[index].id).length ?? 0,
                  lastPlayedAt: _lastPlayedAt(store, libraries[index].id),
                  onOpen: () => unawaited(
                    pushPage(
                      context,
                      LocalLibraryDetailPage(
                        libraryId: libraries[index].id,
                        store: widget.store,
                        actions: widget.actions,
                        bridge: widget.bridge,
                      ),
                    ),
                  ),
                  onRescan: libraries[index].kind == LocalLibraryKind.folder
                      ? () => unawaited(
                            runLocalLibraryAction((a) => a.rescan(libraries[index])),
                          )
                      : null,
                  onRemove: () => unawaited(_removeLibrary(libraries[index])),
                ),
              ),
          ],
        ],
      ),
    );
  }

  int? _lastPlayedAt(LocalMediaStore? store, String libraryId) {
    if (store == null) return null;
    int? newest;
    for (final item in store.items(libraryId)) {
      final stamp = item.lastPlayedAt;
      if (stamp == null) continue;
      if (newest == null || stamp > newest) newest = stamp;
    }
    return newest;
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({
    required this.library,
    required this.itemCount,
    required this.lastPlayedAt,
    required this.onOpen,
    required this.onRescan,
    required this.onRemove,
  });

  final LocalLibrary library;
  final int itemCount;
  final int? lastPlayedAt;
  final VoidCallback onOpen;

  /// null 表示这个库不适合重扫(文件型库没有可枚举的根)。
  final VoidCallback? onRescan;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final meta = <String>[
      l10n.local_itemCount(itemCount),
      if (lastPlayedAt != null && lastPlayedAt! > 0)
        '${l10n.local_lastPlayed} ${_whenLabel(lastPlayedAt!)}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        radius: 8,
        onTap: onOpen,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                library.kind == LocalLibraryKind.folder
                    ? Icons.folder_rounded
                    : Icons.movie_rounded,
                size: 19,
                color: p.accent,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    library.name.isEmpty ? l10n.local_unknownTitle : library.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.textMuted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: l10n.local_rescan,
              icon: Icon(Icons.more_vert_rounded, size: 20, color: p.textMuted),
              onSelected: (value) {
                if (value == 'rescan') onRescan?.call();
                if (value == 'remove') onRemove();
              },
              itemBuilder: (ctx) => [
                if (onRescan != null)
                  PopupMenuItem<String>(
                    value: 'rescan',
                    child: Row(
                      children: [
                        Icon(Icons.refresh_rounded, size: 18, color: ctx.palette.textMuted),
                        const SizedBox(width: 8),
                        Text(ctx.l10n.local_rescan),
                      ],
                    ),
                  ),
                PopupMenuItem<String>(
                  value: 'remove',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded,
                          size: 18, color: ctx.palette.textMuted),
                      const SizedBox(width: 8),
                      Text(ctx.l10n.local_removeLibrary),
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

/// 时间戳 → `HH:mm`(今天)或 `MM-dd HH:mm`。
String _whenLabel(int epochMs) {
  final at = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final time = '${two(at.hour)}:${two(at.minute)}';
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return time;
  }
  return '${two(at.month)}-${two(at.day)} $time';
}
