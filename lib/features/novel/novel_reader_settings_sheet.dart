import 'package:flutter/material.dart';

import '../../app/novel_library_store.dart';
import '../../core/l10n/app_strings.dart';

Future<void> showNovelReaderSettings({
  required BuildContext context,
  required NovelReaderPreferences value,
  required ValueChanged<NovelReaderPreferences> onChanged,
}) {
  if (MediaQuery.sizeOf(context).width >= 700) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, __) => Align(
        alignment: Alignment.centerRight,
        child: SafeArea(
          child: SizedBox(
            width: 420,
            height: double.infinity,
            child: Material(
              elevation: 12,
              color: Theme.of(context).colorScheme.surface,
              child: NovelReaderSettingsSheet(
                value: value,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
        child: child,
      ),
    );
  }
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
            DropdownButtonFormField<String>(
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
            const SizedBox(height: 14),
            _ThemePicker(
              label: context.l10n.novel_readerTheme,
              value: _value.theme,
              labels: {
                NovelReaderTheme.sepia: context.l10n.novel_readerThemeSepia,
                NovelReaderTheme.white: context.l10n.novel_readerThemeWhite,
                NovelReaderTheme.dark: context.l10n.novel_readerThemeDark,
                NovelReaderTheme.black: context.l10n.novel_readerThemeBlack,
              },
              onChanged: (value) => _update(_value.copyWith(theme: value)),
            ),
            const SizedBox(height: 14),
            _FontSizeStepper(
              label: context.l10n.novel_readerFontSize,
              value: _value.fontSize,
              onChanged: (value) => _update(
                _value.copyWith(fontSize: value.clamp(12, 32).toDouble()),
              ),
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
            _SettingSlider(
              label: context.l10n.novel_readerAutoHide,
              value: _value.toolbarAutoHideSeconds.toDouble(),
              min: 0,
              max: 10,
              divisions: 10,
              valueLabel: _value.toolbarAutoHideSeconds == 0
                  ? context.l10n.novel_readerAutoHideOff
                  : context.l10n.novel_readerSeconds(
                      _value.toolbarAutoHideSeconds,
                    ),
              onChanged: (value) => _update(
                _value.copyWith(toolbarAutoHideSeconds: value.round()),
              ),
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
    this.valueLabel,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final String? valueLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 112, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel ??
                value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 58,
          child: Text(
            valueLabel ?? value.toStringAsFixed(1),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

class _FontSizeStepper extends StatelessWidget {
  const _FontSizeStepper({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 112, child: Text(label)),
        IconButton.outlined(
          tooltip: '$label -',
          onPressed: value <= 12 ? null : () => onChanged(value - 1),
          icon: const Icon(Icons.remove_rounded),
        ),
        Expanded(
          child: Text(
            'A  ${value.round()}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton.outlined(
          tooltip: '$label +',
          onPressed: value >= 32 ? null : () => onChanged(value + 1),
          icon: const Icon(Icons.add_rounded),
        ),
      ],
    );
  }
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({
    required this.label,
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final String label;
  final NovelReaderTheme value;
  final Map<NovelReaderTheme, String> labels;
  final ValueChanged<NovelReaderTheme> onChanged;

  static const _colors = {
    NovelReaderTheme.sepia: Color(0xfff2e8cf),
    NovelReaderTheme.white: Color(0xffffffff),
    NovelReaderTheme.dark: Color(0xff292b2f),
    NovelReaderTheme.black: Color(0xff050505),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(width: 112, child: Text(label)),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 10,
            runSpacing: 8,
            children: [
              for (final theme in NovelReaderTheme.values)
                Tooltip(
                  message: labels[theme] ?? theme.name,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onChanged(theme),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: _colors[theme],
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: value == theme
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: value == theme ? 3 : 1,
                        ),
                      ),
                      child: value == theme
                          ? Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: theme == NovelReaderTheme.dark ||
                                      theme == NovelReaderTheme.black
                                  ? Colors.white
                                  : Colors.black87,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
