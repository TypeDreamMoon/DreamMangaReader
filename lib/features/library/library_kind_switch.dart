import 'package:flutter/material.dart';

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
      segments: const [
        ButtonSegment(value: LibraryKind.manga, label: Text('漫画')),
        ButtonSegment(value: LibraryKind.novel, label: Text('小说')),
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
