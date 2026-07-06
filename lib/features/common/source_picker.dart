import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/source_registry.dart';
import 'animations.dart';
import 'glass.dart';

/// 触发源选择弹层的胶囊按钮(书架/发现共用)。
class SourcePickerPill extends StatelessWidget {
  const SourcePickerPill({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = Icons.dashboard_rounded,
  });

  final String label;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: p.accent),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: p.textMuted),
          ],
        ),
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
}) {
  final store = LibraryScope.read(context);
  final sources = [
    for (final s in registeredSources)
      if (store.isSourceEnabled(s.id) || s.id == currentId) s,
  ];
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      final p = ctx.palette;
      return GlassSurface(
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(22)),
        blur: 24,
        border: Border.all(color: p.line),
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.72),
          child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                    color: p.line, borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Row(
                  children: [
                    Icon(Icons.dashboard_rounded, size: 18, color: p.accent),
                    const SizedBox(width: 8),
                    Text('选择漫画源',
                        style: TextStyle(
                            color: p.textPrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: 16)),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  // 左 8 + 卡片内 12 = 20,与标题行左缘对齐;底部留够、不贴弹层边。
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                  children: [
                    if (includeMixed)
                      _SourceRow(
                        glyph: '混',
                        name: '混合 · 全部源',
                        subtitle: '同时搜索 / 浏览所有启用的源',
                        selected: currentId == mixedId,
                        onTap: () => Navigator.pop(ctx, mixedId),
                      ),
                    for (final s in sources)
                      _SourceRow(
                        glyph: s.name.characters.first,
                        name: s.name,
                        subtitle: s.experimental ? '实验性' : null,
                        selected: currentId == s.id,
                        onTap: () => Navigator.pop(ctx, s.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ));
    },
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
