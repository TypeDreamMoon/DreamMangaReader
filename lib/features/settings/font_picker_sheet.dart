import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';

/// 系统字体选择器:搜索 + **懒加载**列表(每行用该字体渲染,ListView.builder
/// 只建可见项 → 只加载看得到的字体,几百个字体也不卡)。
/// 返回选中的字体族名('' = 系统默认;取消/关闭返回 null)。
class FontPickerSheet extends StatefulWidget {
  const FontPickerSheet({
    super.key,
    required this.fonts,
    required this.current,
  });

  final List<String> fonts;
  final String current;

  @override
  State<FontPickerSheet> createState() => _FontPickerSheetState();
}

class _FontPickerSheetState extends State<FontPickerSheet> {
  final TextEditingController _c = TextEditingController();
  late List<String> _filtered = widget.fonts;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _filter(String q) {
    final s = q.trim().toLowerCase();
    setState(() => _filtered = s.isEmpty
        ? widget.fonts
        : widget.fonts.where((f) => f.toLowerCase().contains(s)).toList());
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.72,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('选择字体',
                        style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800)),
                    const Spacer(),
                    Text('${widget.fonts.length} 个',
                        style: TextStyle(color: p.textMuted, fontSize: 12)),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 20),
                      color: p.textMuted,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _c,
                  onChanged: _filter,
                  style: TextStyle(color: p.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索字体名',
                    hintStyle: TextStyle(color: p.textMuted),
                    prefixIcon: Icon(Icons.search_rounded, color: p.textMuted),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: _filtered.length + 1,
                    itemBuilder: (_, i) {
                      // 首行固定「系统默认」(空字符串)。
                      final family = i == 0 ? '' : _filtered[i - 1];
                      return _row(p, family);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(AppPalette p, String family) {
    final sel = family == widget.current;
    final label = family.isEmpty ? '系统默认' : family;
    return InkWell(
      onTap: () => Navigator.of(context).pop(family),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  // 每行用该字体自身渲染(空=默认回退栈)。
                  fontFamily: family.isEmpty ? null : family,
                  fontFamilyFallback: kFontFallback,
                  color: sel ? p.accent : p.textPrimary,
                  fontSize: 15,
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (sel) Icon(Icons.check_rounded, size: 18, color: p.accent),
          ],
        ),
      ),
    );
  }
}
