import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';

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
      segments: [
        ButtonSegment(
          value: DownloadKind.manga,
          label: Text(context.l10n.content_manga),
        ),
        ButtonSegment(
          value: DownloadKind.novel,
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
