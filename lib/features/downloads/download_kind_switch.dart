import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';

enum DownloadKind { anime, manga, novel }

enum DownloadViewMode { active, completed }

class DownloadKindSwitch extends StatelessWidget {
  const DownloadKindSwitch({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final DownloadKind selected;
  final ValueChanged<DownloadKind> onSelected;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 600) {
      return PopupMenuButton<DownloadKind>(
        initialValue: selected,
        tooltip: _label(context, selected),
        onSelected: onSelected,
        icon: Icon(_icon(selected)),
        itemBuilder: (context) => [
          for (final kind in DownloadKind.values)
            PopupMenuItem(
              value: kind,
              child: Row(
                children: [
                  Icon(_icon(kind), size: 18),
                  const SizedBox(width: 10),
                  Text(_label(context, kind)),
                ],
              ),
            ),
        ],
      );
    }
    return SegmentedButton<DownloadKind>(
      segments: [
        for (final kind in DownloadKind.values)
          ButtonSegment(
            value: kind,
            icon: Icon(_icon(kind), size: 16),
            label: Text(_label(context, kind)),
          ),
      ],
      selected: {selected},
      onSelectionChanged: (values) => onSelected(values.single),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  String _label(BuildContext context, DownloadKind kind) => switch (kind) {
        DownloadKind.anime => context.l10n.content_anime,
        DownloadKind.manga => context.l10n.content_manga,
        DownloadKind.novel => context.l10n.content_novel,
      };

  IconData _icon(DownloadKind kind) => switch (kind) {
        DownloadKind.anime => Icons.movie_outlined,
        DownloadKind.manga => Icons.photo_library_outlined,
        DownloadKind.novel => Icons.menu_book_outlined,
      };
}

class DownloadViewModeSwitch extends StatelessWidget {
  const DownloadViewModeSwitch({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final DownloadViewMode selected;
  final ValueChanged<DownloadViewMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DownloadViewMode>(
      segments: [
        ButtonSegment(
          value: DownloadViewMode.active,
          icon: const Icon(Icons.downloading_rounded, size: 17),
          tooltip: context.l10n.download_active,
        ),
        ButtonSegment(
          value: DownloadViewMode.completed,
          icon: const Icon(Icons.download_done_rounded, size: 17),
          tooltip: context.l10n.download_completed,
        ),
      ],
      selected: {selected},
      onSelectionChanged: (values) => onSelected(values.single),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
