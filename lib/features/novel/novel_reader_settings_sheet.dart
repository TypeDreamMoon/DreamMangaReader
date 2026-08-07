import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/novel_library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/reader/novel_background_store.dart';
import '../../core/novel/reader/novel_font_store.dart';
import '../../core/novel/reader/novel_reader_models.dart';

typedef NovelFontFilePicker = Future<File?> Function();
typedef NovelBackgroundFilePicker = Future<File?> Function();

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
              color: context.palette.surface,
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
    this.fontStore,
    this.pickFontFile,
    this.backgroundStore,
    this.pickBackgroundFile,
  });

  final NovelReaderPreferences value;
  final ValueChanged<NovelReaderPreferences> onChanged;
  final NovelFontStore? fontStore;
  final NovelFontFilePicker? pickFontFile;
  final NovelBackgroundStore? backgroundStore;
  final NovelBackgroundFilePicker? pickBackgroundFile;

  @override
  State<NovelReaderSettingsSheet> createState() =>
      _NovelReaderSettingsSheetState();
}

class _NovelReaderSettingsSheetState extends State<NovelReaderSettingsSheet> {
  late NovelReaderPreferences _value = widget.value;
  late final NovelFontStore _fontStore = widget.fontStore ?? NovelFontStore();
  late final NovelBackgroundStore _backgroundStore =
      widget.backgroundStore ?? NovelBackgroundStore();
  List<NovelFontRecord> _importedFonts = const [];

  @override
  void initState() {
    super.initState();
    _reloadImportedFonts();
  }

  Future<void> _reloadImportedFonts() async {
    try {
      final fonts = await _fontStore.listImportedFonts();
      if (!mounted) return;
      final selected = normalizeNovelFontId(_value.fontFamily);
      final selectedMissing =
          selected.startsWith(NovelFontIds.importedPrefix) &&
              !fonts.any((font) => font.id == selected);
      if (selectedMissing) {
        final fallback = _value.copyWith(fontFamily: NovelFontIds.notoSerifSc);
        setState(() {
          _importedFonts = fonts;
          _value = fallback;
        });
        widget.onChanged(fallback);
      } else {
        setState(() => _importedFonts = fonts);
      }
    } catch (_) {
      // The picker remains usable even when the platform support directory
      // is temporarily unavailable.
    }
  }

  Future<void> _importFont() async {
    try {
      final source = await (widget.pickFontFile?.call() ?? _pickFontFile());
      if (source == null) return;
      final font = await _fontStore.importFont(source);
      await _reloadImportedFonts();
      if (mounted) _update(_value.copyWith(fontFamily: font.id));
    } on NovelFontImportException catch (error) {
      _showFontError(error.message);
    } catch (_) {
      _showFontError('字体导入失败，请检查文件后重试。');
    }
  }

  Future<void> _deleteSelectedFont() async {
    final selected = normalizeNovelFontId(_value.fontFamily);
    if (!selected.startsWith(NovelFontIds.importedPrefix)) return;
    try {
      final fallback = await _fontStore.deleteFont(
        selected,
        selectedId: selected,
      );
      if (!mounted) return;
      _update(_value.copyWith(fontFamily: fallback));
      await _reloadImportedFonts();
    } catch (_) {
      _showFontError('字体删除失败，请稍后重试。');
    }
  }

  Future<void> _importBackground() async {
    try {
      final source =
          await (widget.pickBackgroundFile?.call() ?? _pickBackgroundFile());
      if (source == null) return;
      final background = await _backgroundStore.importImage(source);
      if (mounted) {
        _update(_value.copyWith(backgroundAssetId: background.id));
        await _backgroundStore.deleteUnreferenced({background.id});
      }
    } on NovelBackgroundException catch (error) {
      _showFontError(error.message);
    } catch (_) {
      _showFontError('背景导入失败，请检查图片后重试。');
    }
  }

  Future<void> _clearBackground() async {
    _update(_value.copyWith(clearBackgroundAsset: true));
    await _backgroundStore.deleteUnreferenced(const {});
  }

  void _showFontError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _update(NovelReaderPreferences value) {
    setState(() => _value = value);
    widget.onChanged(value);
  }

  Widget _statusSwitch({
    required Key key,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: value,
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    final selectedFontId = normalizeNovelFontId(_value.fontFamily);
    final selectedImportPending =
        selectedFontId.startsWith(NovelFontIds.importedPrefix) &&
            !_importedFonts.any((font) => font.id == selectedFontId);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 660),
        child: ListView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottom),
          children: [
            Text(
              context.l10n.reader_settings,
              style: TextStyle(
                color: context.palette.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in NovelPageTurnMode.values)
                  ChoiceChip(
                    key: Key('novel-turn-mode-${mode.name}'),
                    selected: _value.turnMode == mode,
                    label: Text(_turnModeLabel(context, mode)),
                    avatar: Icon(_turnModeIcon(mode), size: 18),
                    onSelected: (_) => _update(_value.copyWith(turnMode: mode)),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: const Key('novel-font-picker'),
                    initialValue: normalizeNovelFontId(_value.fontFamily),
                    decoration: InputDecoration(
                      labelText: context.l10n.novel_readerFont,
                    ),
                    items: [
                      for (final font in novelBuiltinFonts)
                        DropdownMenuItem(
                          value: font.id,
                          child: Text(font.displayName),
                        ),
                      for (final font in _importedFonts)
                        DropdownMenuItem(
                          value: font.id,
                          child: Text(font.displayName),
                        ),
                      if (selectedImportPending)
                        DropdownMenuItem(
                          value: selectedFontId,
                          child: const Text('正在检查自定义字体...'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        _update(_value.copyWith(fontFamily: value));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('novel-font-import'),
                  tooltip: '导入 TTF/OTF 字体',
                  onPressed: _importFont,
                  icon: const Icon(Icons.add_rounded),
                ),
                IconButton(
                  key: const Key('novel-font-delete'),
                  tooltip: '删除当前导入字体',
                  onPressed: normalizeNovelFontId(_value.fontFamily)
                          .startsWith(NovelFontIds.importedPrefix)
                      ? _deleteSelectedFont
                      : null,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _ThemePicker(
              label: context.l10n.novel_readerTheme,
              value: _value.theme,
              labels: {
                NovelReaderTheme.white: context.l10n.novel_readerThemeWhite,
                NovelReaderTheme.eyeCare: context.l10n.novel_readerThemeSepia,
                NovelReaderTheme.dark: context.l10n.novel_readerThemeDark,
                NovelReaderTheme.black: context.l10n.novel_readerThemeBlack,
                NovelReaderTheme.paper: '纸张',
              },
              onChanged: (value) => _update(_value.copyWith(theme: value)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('novel-background-import'),
                  onPressed: _importBackground,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('导入背景'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('novel-background-clear'),
                  tooltip: '清除自定义背景',
                  onPressed: _value.backgroundAssetId == null
                      ? null
                      : () async => _clearBackground(),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
                if (_value.backgroundAssetId != null)
                  const Expanded(
                    child: Text(
                      '已使用本地背景',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final fit in NovelBackgroundFit.values)
                  ChoiceChip(
                    key: Key('novel-background-fit-${fit.name}'),
                    selected: _value.backgroundFit == fit,
                    label: Text(switch (fit) {
                      NovelBackgroundFit.crop => '裁剪',
                      NovelBackgroundFit.tile => '平铺',
                      NovelBackgroundFit.fill => '填充',
                    }),
                    onSelected: (_) =>
                        _update(_value.copyWith(backgroundFit: fit)),
                  ),
              ],
            ),
            _SettingSlider(
              key: const Key('novel-background-strength'),
              label: '纹理强度',
              value: _value.textureStrength,
              min: 0,
              max: 1,
              divisions: 20,
              valueLabel: '${(_value.textureStrength * 100).round()}%',
              onChanged: (value) =>
                  _update(_value.copyWith(textureStrength: value)),
            ),
            SegmentedButton<int?>(
              key: const Key('novel-foreground-mode'),
              segments: const [
                ButtonSegment(value: null, label: Text('自动')),
                ButtonSegment(value: 0xff202124, label: Text('深色字')),
                ButtonSegment(value: 0xffeeeeee, label: Text('浅色字')),
              ],
              selected: {_value.foregroundArgb},
              onSelectionChanged: (selection) {
                final selected = selection.first;
                _update(
                  selected == null
                      ? _value.copyWith(clearForeground: true)
                      : _value.copyWith(foregroundArgb: selected),
                );
              },
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
              key: const Key('novel-setting-brightness'),
              label: '亮度',
              value: _value.brightness,
              min: .6,
              max: 1.4,
              divisions: 16,
              valueLabel: '${(_value.brightness * 100).round()}%',
              onChanged: (value) => _update(_value.copyWith(brightness: value)),
            ),
            _SettingSlider(
              key: const Key('novel-setting-line-height'),
              label: context.l10n.novel_readerLineHeight,
              value: _value.lineHeight,
              min: 1.2,
              max: 2.4,
              divisions: 12,
              onChanged: (value) => _update(_value.copyWith(lineHeight: value)),
            ),
            _SettingSlider(
              key: const Key('novel-setting-paragraph-spacing'),
              label: context.l10n.novel_readerParagraphSpacing,
              value: _value.paragraphSpacing,
              min: 0,
              max: 30,
              divisions: 15,
              onChanged: (value) =>
                  _update(_value.copyWith(paragraphSpacing: value)),
            ),
            _SettingSlider(
              key: const Key('novel-setting-horizontal-margin'),
              label: context.l10n.novel_readerHorizontalMargin,
              value: _value.horizontalMargin,
              min: 8,
              max: 56,
              divisions: 24,
              onChanged: (value) =>
                  _update(_value.copyWith(horizontalMargin: value)),
            ),
            _SettingSlider(
              key: const Key('novel-setting-top-margin'),
              label: '上边距',
              value: _value.topMargin,
              min: 0,
              max: 96,
              divisions: 24,
              onChanged: (value) => _update(_value.copyWith(topMargin: value)),
            ),
            _SettingSlider(
              key: const Key('novel-setting-bottom-margin'),
              label: '下边距',
              value: _value.bottomMargin,
              min: 0,
              max: 96,
              divisions: 24,
              onChanged: (value) =>
                  _update(_value.copyWith(bottomMargin: value)),
            ),
            _SettingSlider(
              key: const Key('novel-setting-first-line-indent'),
              label: '首行缩进',
              value: _value.firstLineIndent,
              min: 0,
              max: 4,
              divisions: 8,
              onChanged: (value) =>
                  _update(_value.copyWith(firstLineIndent: value)),
            ),
            Padding(
              key: const Key('novel-setting-alignment'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SegmentedButton<NovelTextAlignment>(
                segments: const [
                  ButtonSegment(
                    value: NovelTextAlignment.start,
                    label: Text('左对齐'),
                  ),
                  ButtonSegment(
                    value: NovelTextAlignment.justify,
                    label: Text('两端对齐'),
                  ),
                ],
                selected: {_value.textAlignment},
                onSelectionChanged: (selection) => _update(
                  _value.copyWith(textAlignment: selection.first),
                ),
              ),
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
              key: const Key('novel-setting-single-hand'),
              contentPadding: EdgeInsets.zero,
              title: const Text('单手翻下一页'),
              value: _value.singleHandNext,
              onChanged: (value) =>
                  _update(_value.copyWith(singleHandNext: value)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.novel_readerKeepScreenOn),
              value: _value.keepScreenOn,
              onChanged: (value) =>
                  _update(_value.copyWith(keepScreenOn: value)),
            ),
            _statusSwitch(
              key: const Key('novel-setting-status-chapter'),
              label: '显示章节名',
              value: _value.showChapterName,
              onChanged: (value) =>
                  _update(_value.copyWith(showChapterName: value)),
            ),
            _statusSwitch(
              key: const Key('novel-setting-status-page'),
              label: '显示页码',
              value: _value.showPageNumber,
              onChanged: (value) =>
                  _update(_value.copyWith(showPageNumber: value)),
            ),
            _statusSwitch(
              key: const Key('novel-setting-status-progress'),
              label: '显示全书进度',
              value: _value.showBookProgress,
              onChanged: (value) =>
                  _update(_value.copyWith(showBookProgress: value)),
            ),
            _statusSwitch(
              key: const Key('novel-setting-status-time'),
              label: '显示时间',
              value: _value.showTime,
              onChanged: (value) => _update(_value.copyWith(showTime: value)),
            ),
            _statusSwitch(
              key: const Key('novel-setting-status-battery'),
              label: '显示电量',
              value: _value.showBattery,
              onChanged: (value) =>
                  _update(_value.copyWith(showBattery: value)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('novel-setting-reset'),
              onPressed: () => _update(const NovelReaderPreferences()),
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('恢复默认设置'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<File?> _pickFontFile() async {
  final selection = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['ttf', 'otf'],
    allowMultiple: false,
  );
  final path = selection?.files.single.path;
  return path == null || path.isEmpty ? null : File(path);
}

Future<File?> _pickBackgroundFile() async {
  final selection = await FilePicker.pickFiles(
    type: FileType.image,
    allowMultiple: false,
  );
  final path = selection?.files.single.path;
  return path == null || path.isEmpty ? null : File(path);
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    super.key,
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

String _turnModeLabel(BuildContext context, NovelPageTurnMode mode) =>
    switch (mode) {
      NovelPageTurnMode.curl => '仿真',
      NovelPageTurnMode.cover => '覆盖',
      NovelPageTurnMode.translate => '平移',
      NovelPageTurnMode.none => '无动画',
      NovelPageTurnMode.scroll => context.l10n.novel_readerScroll,
    };

IconData _turnModeIcon(NovelPageTurnMode mode) => switch (mode) {
      NovelPageTurnMode.curl => Icons.auto_stories_rounded,
      NovelPageTurnMode.cover => Icons.flip_rounded,
      NovelPageTurnMode.translate => Icons.swap_horiz_rounded,
      NovelPageTurnMode.none => Icons.hide_source_rounded,
      NovelPageTurnMode.scroll => Icons.view_stream_rounded,
    };

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
            style: TextStyle(
              color: context.palette.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
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
    NovelReaderTheme.white: Color(0xffffffff),
    NovelReaderTheme.eyeCare: Color(0xffdfe8cf),
    NovelReaderTheme.dark: Color(0xff292b2f),
    NovelReaderTheme.black: Color(0xff050505),
    NovelReaderTheme.paper: Color(0xffeee5d1),
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        SizedBox(
          width: 112,
          child: Text(label, style: TextStyle(color: p.textPrimary)),
        ),
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
                          color: value == theme ? p.accent : p.line,
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
