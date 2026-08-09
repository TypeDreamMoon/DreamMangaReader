import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/theme_controller.dart';
import '../../core/l10n/app_strings.dart';
import '../../ui/ui.dart';

/// 主题色选择:一排预设色块 +(展开的)色相/饱和/明度滑条。
///
/// 选中的色只覆盖 `accent`,`accentSoft` 与 `onAccent` 由 [AppPalette.withAccent]
/// 按对比度派生 —— 所以随便挑什么色,按钮上的文字都读得出来。
Future<void> showAccentColorSheet(BuildContext context) {
  final theme = ThemeScope.of(context);
  return showAppSheet<void>(
    context,
    title: context.l10n.set_accentColor,
    titleIcon: Icons.color_lens_rounded,
    showDragHandle: true,
    glass: true,
    topRadius: 22,
    bodyPadding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
    body: (ctx, setSheet) => _AccentPicker(theme: theme),
  );
}

class _AccentPicker extends StatefulWidget {
  const _AccentPicker({required this.theme});

  final ThemeController theme;

  @override
  State<_AccentPicker> createState() => _AccentPickerState();
}

class _AccentPickerState extends State<_AccentPicker> {
  late HSLColor _hsl =
      HSLColor.fromColor(widget.theme.accent ?? context.palette.accent);
  late bool _custom = widget.theme.accent != null &&
      !kAccentPresets.contains(widget.theme.accent);

  void _apply(Color? value) {
    widget.theme.accent = value;
    if (value != null) _hsl = HSLColor.fromColor(value);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final current = widget.theme.accent;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 「跟随主题」+ 预设色块。
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _Swatch(
              color: p.accent,
              selected: current == null,
              followsTheme: true,
              onTap: () {
                _custom = false;
                _apply(null);
              },
            ),
            for (final preset in kAccentPresets)
              _Swatch(
                color: preset,
                selected: current == preset,
                onTap: () {
                  _custom = false;
                  _apply(preset);
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        AppSelectableRow(
          icon: Icons.tune_rounded,
          title: context.l10n.set_accentCustom,
          selected: _custom,
          onTap: () => setState(() {
            _custom = !_custom;
            if (_custom) _apply(_hsl.toColor());
          }),
        ),
        if (_custom) ...[
          const SizedBox(height: 8),
          // 色相条:直接把当前饱和/明度铺成一条彩虹,拖到哪就是哪。
          _HueBar(
            hsl: _hsl,
            onChanged: (hue) => _apply(_hsl.withHue(hue).toColor()),
          ),
          const SizedBox(height: 4),
          AppSliderRow(
            icon: Icons.opacity_rounded,
            label: context.l10n.set_accentSaturation,
            value: _hsl.saturation,
            min: 0,
            max: 1,
            pct: true,
            onChanged: (v) => _apply(_hsl.withSaturation(v).toColor()),
          ),
          AppSliderRow(
            icon: Icons.brightness_6_rounded,
            label: context.l10n.set_accentLightness,
            value: _hsl.lightness,
            min: 0.15,
            max: 0.85,
            pct: true,
            onChanged: (v) => _apply(_hsl.withLightness(v).toColor()),
          ),
        ],
        const SizedBox(height: 14),
        _Preview(accent: current ?? p.accent),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.followsTheme = false,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  /// 「跟随主题」那一格:同样显示当前主题色,但角上加个标记以示区别。
  final bool followsTheme;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Pressable(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? p.textPrimary : p.line,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: followsTheme
            ? Icon(Icons.auto_awesome_rounded,
                size: 16, color: p.onAccent.withValues(alpha: 0.85))
            : (selected
                ? Icon(Icons.check_rounded, size: 20, color: p.onAccent)
                : null),
      ),
    );
  }
}

/// 色相滑条。底是一条 HSL 彩虹(饱和/明度取当前值),拇指停在当前色相上。
class _HueBar extends StatelessWidget {
  const _HueBar({required this.hsl, required this.onChanged});

  final HSLColor hsl;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            Container(
              height: 14,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                gradient: LinearGradient(
                  colors: [
                    for (var h = 0; h <= 360; h += 30)
                      HSLColor.fromAHSL(1, h % 360, hsl.saturation,
                              hsl.lightness)
                          .toColor(),
                  ],
                ),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
              ),
              child: Slider(
                value: hsl.hue,
                max: 360,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      );
}

/// 现场预览:主按钮 + 高亮文字,直接看清 onAccent 派生得对不对。
class _Preview extends StatelessWidget {
  const _Preview({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    final derived = context.palette.withAccent(accent);
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: () {},
              style: FilledButton.styleFrom(
                backgroundColor: derived.accent,
                foregroundColor: derived.onAccent,
                minimumSize: const Size.fromHeight(40),
              ),
              child: Text(context.l10n.set_accentPreview,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.favorite_rounded, color: derived.accentSoft, size: 22),
        ],
      ),
    );
  }
}
