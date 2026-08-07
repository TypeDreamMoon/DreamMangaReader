import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/novel/reader/novel_reader_models.dart';

class NovelReaderSelectionBar extends StatelessWidget {
  const NovelReaderSelectionBar({
    super.key,
    required this.selection,
    required this.onCopy,
    required this.onHighlight,
    required this.onNote,
    required this.onSearch,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final NovelSelection selection;
  final VoidCallback onCopy;
  final VoidCallback onHighlight;
  final VoidCallback onNote;
  final VoidCallback onSearch;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('novel-selection-bar'),
      color: backgroundColor,
      elevation: 8,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        label: context.l10n.novel_readerSelectedCharacters(
          selection.text.length,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _action(
              key: const Key('novel-selection-copy'),
              tooltip: context.l10n.novel_readerCopy,
              icon: Icons.content_copy_rounded,
              onPressed: onCopy,
            ),
            _action(
              key: const Key('novel-selection-highlight'),
              tooltip: context.l10n.novel_readerHighlight,
              icon: Icons.border_color_rounded,
              onPressed: onHighlight,
            ),
            _action(
              key: const Key('novel-selection-note'),
              tooltip: context.l10n.novel_readerNoteTitle,
              icon: Icons.edit_note_rounded,
              onPressed: onNote,
            ),
            _action(
              key: const Key('novel-selection-search'),
              tooltip: context.l10n.novel_readerSearchInBook,
              icon: Icons.search_rounded,
              onPressed: onSearch,
            ),
          ],
        ),
      ),
    );
  }

  Widget _action({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      color: foregroundColor,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}
