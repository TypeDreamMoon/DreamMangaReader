import 'package:flutter/material.dart';

import '../../app/novel_library_store.dart';

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
            Text('阅读设置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            SegmentedButton<NovelReaderMode>(
              segments: const [
                ButtonSegment(
                  value: NovelReaderMode.paged,
                  icon: Icon(Icons.menu_book_rounded),
                  label: Text('分页阅读'),
                ),
                ButtonSegment(
                  value: NovelReaderMode.scroll,
                  icon: Icon(Icons.view_stream_rounded),
                  label: Text('连续滚动'),
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
                    decoration: const InputDecoration(labelText: '字体'),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('系统默认')),
                      DropdownMenuItem(value: 'serif', child: Text('衬线字体')),
                      DropdownMenuItem(
                        value: 'sans-serif',
                        child: Text('无衬线字体'),
                      ),
                      DropdownMenuItem(
                        value: 'monospace',
                        child: Text('等宽字体'),
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
                    decoration: const InputDecoration(labelText: '页面主题'),
                    items: const [
                      DropdownMenuItem(
                        value: NovelReaderTheme.sepia,
                        child: Text('护眼'),
                      ),
                      DropdownMenuItem(
                        value: NovelReaderTheme.white,
                        child: Text('白色'),
                      ),
                      DropdownMenuItem(
                        value: NovelReaderTheme.dark,
                        child: Text('深色'),
                      ),
                      DropdownMenuItem(
                        value: NovelReaderTheme.black,
                        child: Text('纯黑'),
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
              label: '字号',
              value: _value.fontSize,
              min: 12,
              max: 32,
              divisions: 20,
              onChanged: (value) => _update(_value.copyWith(fontSize: value)),
            ),
            _SettingSlider(
              label: '行高',
              value: _value.lineHeight,
              min: 1.2,
              max: 2.4,
              divisions: 12,
              onChanged: (value) => _update(_value.copyWith(lineHeight: value)),
            ),
            _SettingSlider(
              label: '段落间距',
              value: _value.paragraphSpacing,
              min: 0,
              max: 30,
              divisions: 15,
              onChanged: (value) =>
                  _update(_value.copyWith(paragraphSpacing: value)),
            ),
            _SettingSlider(
              label: '左右边距',
              value: _value.horizontalMargin,
              min: 8,
              max: 56,
              divisions: 24,
              onChanged: (value) =>
                  _update(_value.copyWith(horizontalMargin: value)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('阅读时保持屏幕常亮'),
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
