import 'package:flutter/material.dart';

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
        label: '已选择 ${selection.text.length} 个字符',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _action(
              key: const Key('novel-selection-copy'),
              tooltip: '复制',
              icon: Icons.content_copy_rounded,
              onPressed: onCopy,
            ),
            _action(
              key: const Key('novel-selection-highlight'),
              tooltip: '高亮',
              icon: Icons.border_color_rounded,
              onPressed: onHighlight,
            ),
            _action(
              key: const Key('novel-selection-note'),
              tooltip: '笔记',
              icon: Icons.edit_note_rounded,
              onPressed: onNote,
            ),
            _action(
              key: const Key('novel-selection-search'),
              tooltip: '书内搜索',
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
