import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';

enum LibraryKind { manga, novel }

class LibraryKindSwitch extends StatelessWidget {
  const LibraryKindSwitch({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final LibraryKind selected;
  final ValueChanged<LibraryKind> onSelected;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<LibraryKind>(
      segments: [
        ButtonSegment(
          value: LibraryKind.manga,
          label: Text(context.l10n.content_manga),
        ),
        ButtonSegment(
          value: LibraryKind.novel,
          label: Text(context.l10n.content_novel),
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
