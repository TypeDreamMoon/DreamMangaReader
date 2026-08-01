import 'package:flutter/material.dart';

import '../../app/novel_library_store.dart';
import '../../core/l10n/app_strings.dart';

Future<void> showNovelReaderSettings({
  required BuildContext context,
  required NovelReaderPreferences value,
  required ValueChanged<NovelReaderPreferences> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => NovelReaderSettingsSheet(
      value: value,
      onChanged: onChanged,
    ),
  );
}

class NovelReaderSettingsSheet extends StatefulWidget {
  const NovelReaderSettingsSheet({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final NovelReaderPreferences value;
  final ValueChanged<NovelReaderPreferences> onChanged;

  @override
  State<NovelReaderSettingsSheet> createState() =>
      _NovelReaderSettingsSheetState();
}

class _NovelReaderSettingsSheetState extends State<NovelReaderSettingsSheet> {
  late NovelReaderPreferences _value = widget.value;

  void _update(NovelReaderPreferences value) {
    setState(() => _value = value);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 660),
        child: ListView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottom),
          children: [
            Text(
              context.l10n.reader_settings,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            SegmentedButton<NovelReaderMode>(
              segments: [
                ButtonSegment(
                  value: NovelReaderMode.paged,
                  icon: const Icon(Icons.menu_book_rounded),
                  label: Text(context.l10n.novel_readerPaged),
                ),
                ButtonSegment(
                  value: NovelReaderMode.scroll,
                  icon: const Icon(Icons.view_stream_rounded),
                  label: Text(context.l10n.novel_readerScroll),
                ),
              ],
              selected: {_value.mode},
              onSelectionChanged: (selection) {
                _update(_value.copyWith(mode: selection.first));
              },
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _value.fontFamily,
                    decoration: InputDecoration(
                      labelText: context.l10n.novel_readerFont,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(context.l10n.novel_readerSystemDefault),
                      ),
                      DropdownMenuItem(
                        value: 'serif',
                        child: Text(context.l10n.novel_readerSerif),
                      ),
                      DropdownMenuItem(
                        value: 'sans-serif',
                        child: Text(context.l10n.novel_readerSansSerif),
                      ),
                      DropdownMenuItem(
                        value: 'monospace',
                        child: Text(context.l10n.novel_readerMonospace),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        _update(_value.copyWith(fontFamily: value));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<NovelReaderTheme>(
                    initialValue: _value.theme,
                    decoration: InputDecoration(
                      labelText: context.l10n.novel_readerTheme,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: NovelReaderTheme.sepia,
                        child: Text(context.l10n.novel_readerThemeSepia),
                      ),
                      DropdownMenuItem(
                        value: NovelReaderTheme.white,
                        child: Text(context.l10n.novel_readerThemeWhite),
                      ),
                      DropdownMenuItem(
                        value: NovelReaderTheme.dark,
                        child: Text(context.l10n.novel_readerThemeDark),
                      ),
                      DropdownMenuItem(
                        value: NovelReaderTheme.black,
                        child: Text(context.l10n.novel_readerThemeBlack),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        _update(_value.copyWith(theme: value));
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _SettingSlider(
              label: context.l10n.novel_readerFontSize,
              value: _value.fontSize,
              min: 12,
              max: 32,
              divisions: 20,
              onChanged: (value) => _update(_value.copyWith(fontSize: value)),
            ),
            _SettingSlider(
              label: context.l10n.novel_readerLineHeight,
              value: _value.lineHeight,
              min: 1.2,
              max: 2.4,
              divisions: 12,
              onChanged: (value) => _update(_value.copyWith(lineHeight: value)),
            ),
            _SettingSlider(
              label: context.l10n.novel_readerParagraphSpacing,
              value: _value.paragraphSpacing,
              min: 0,
              max: 30,
              divisions: 15,
              onChanged: (value) =>
                  _update(_value.copyWith(paragraphSpacing: value)),
            ),
            _SettingSlider(
              label: context.l10n.novel_readerHorizontalMargin,
              value: _value.horizontalMargin,
              min: 8,
              max: 56,
              divisions: 24,
              onChanged: (value) =>
                  _update(_value.copyWith(horizontalMargin: value)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.novel_readerKeepScreenOn),
              value: _value.keepScreenOn,
              onChanged: (value) =>
                  _update(_value.copyWith(keepScreenOn: value)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 82, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label:
                value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(value.toStringAsFixed(1), textAlign: TextAlign.end),
        ),
      ],
    );
  }
}
