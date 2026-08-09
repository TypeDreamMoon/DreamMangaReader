import 'package:flutter/material.dart';

import '../../app/content_kind.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';

/// 某一档当前的源状态。三个 browser 各自持有自己的源,发现页要把源标签画到
/// tab 条右端,就靠它们回传这个值。
class SourceSelection {
  const SourceSelection({required this.mixed, this.sourceName});

  /// 混合模式(全部启用源一起查)。
  final bool mixed;

  /// 单源模式下的源名;null = 还没选源。
  final String? sourceName;

  @override
  bool operator ==(Object other) =>
      other is SourceSelection &&
      other.mixed == mixed &&
      other.sourceName == sourceName;

  @override
  int get hashCode => Object.hash(mixed, sourceName);
}

/// tab 条右端的源标签:**无描边、无底色**,accent 图标 + 源名 + 一个小箭头。
///
/// 它答的是「我现在在看哪个源」,是上下文标签而非待填的表单项 —— 所以不做成
/// 描边下拉框(那会和同一行无边框的 [AppUnderlineTabs] 打架),而是像一行面包屑。
class SourcePickerLabel extends StatelessWidget {
  const SourcePickerLabel({
    super.key,
    required this.kind,
    required this.selection,
    required this.onTap,
  });

  final ContentKind kind;
  final SourceSelection selection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final mixed = selection.mixed;
    final label = mixed
        ? context.l10n.disc_mixedAllSources
        : (selection.sourceName ?? context.l10n.disc_selectSource);
    return Pressable(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 混合用「全部源」的方格图标,单源用该内容类型的图标。
          Icon(mixed ? Icons.dashboard_rounded : kind.icon,
              size: 14, color: p.accent),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 2),
          // 箭头压到比文字还小 —— 它是最不重要的那个元素。
          Icon(Icons.keyboard_arrow_down_rounded, size: 15, color: p.textMuted),
        ],
      ),
    );
  }
}

/// 打开底部弹层选择漫画源,返回选中的源 id(或 [mixedId] 表示混合,或 null=取消)。
/// [includeMixed] 时顶部多一个「混合 · 全部源」。比原来那个飘在角落的下拉菜单顺手。
Future<String?> showSourcePicker(
  BuildContext context, {
  required String currentId,
  bool includeMixed = false,
  String mixedId = '__all__',
  String kind = 'manga', // 只列该内容类型的源(漫画/番剧分开选)
}) {
  final store = LibraryScope.read(context);
  final title = switch (kind) {
    'anime' => context.l10n.srcpick_titleAnime,
    'novel' => context.l10n.srcpick_titleNovel,
    _ => context.l10n.srcpick_title,
  };
  final sources = [
    for (final s in registeredSources)
      if (s.kind == kind && (store.isSourceEnabled(s.id) || s.id == currentId))
        s,
  ];
  // 外壳(毛玻璃/圆角/拖拽条/SafeArea/标题「选择漫画源」)统一走 showAppSheet(glass);
  // 源数量少(≤ 全部启用源),随内容自适应即可,无需固定限高。
  return showAppSheet<String>(
    context,
    title: title,
    titleIcon: Icons.dashboard_rounded,
    showDragHandle: true,
    glass: true,
    topRadius: 22,
    bodyPadding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
    body: (ctx, setSheet) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (includeMixed)
          _SourceRow(
            glyph: context.l10n.srcpick_mixedGlyph,
            name: context.l10n.srcpick_mixedAllSources,
            subtitle: context.l10n.srcpick_mixedSubtitle,
            selected: currentId == mixedId,
            onTap: () => Navigator.pop(ctx, mixedId),
          ),
        for (final s in sources)
          _SourceRow(
            glyph: s.name.characters.first,
            name: s.name,
            subtitle: s.experimental ? context.l10n.srcpick_experimental : null,
            selected: currentId == s.id,
            onTap: () => Navigator.pop(ctx, s.id),
          ),
      ],
    ),
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.glyph,
    required this.name,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final String glyph;
  final String name;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: selected ? p.accent.withValues(alpha: 0.12) : p.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: selected
                      ? p.accent.withValues(alpha: 0.5)
                      : p.line),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? p.accent : p.elevated,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(glyph,
                      style: TextStyle(
                          color: selected ? p.onAccent : p.textPrimary,
                          fontWeight: FontWeight.w900,
                          fontSize: 16)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: p.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!,
                            style:
                                TextStyle(color: p.textMuted, fontSize: 11)),
                      ],
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle_rounded, color: p.accent, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
