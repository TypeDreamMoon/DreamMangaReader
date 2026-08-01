import 'package:flutter/material.dart';

enum DownloadKind { manga, novel }

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
    return SegmentedButton<DownloadKind>(
      segments: const [
        ButtonSegment(value: DownloadKind.manga, label: Text('漫画')),
        ButtonSegment(value: DownloadKind.novel, label: Text('小说')),
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
