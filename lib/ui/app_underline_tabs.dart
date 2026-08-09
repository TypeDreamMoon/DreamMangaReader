import 'package:flutter/material.dart';

import '../app/library_store.dart' show LibraryStore;
import '../app/theme/app_colors.dart';

/// 一个 tab 档:值 + 标签(+ 可选前导图标 / 尾部计数)。
class AppUnderlineTab<T> {
  const AppUnderlineTab({
    required this.value,
    required this.label,
    this.icon,
    this.count,
    this.tabKey,
  });

  final T value;
  final String label;
  final IconData? icon;

  /// 尾部小号计数;null = 不显示。
  final int? count;

  /// 该档的 Key(测试/语义定位用)。
  final Key? tabKey;
}

/// 下划线 Tab 条:文字 + 选中项下方一道 accent 渐变短横。
///
/// 那道短横是 [AppSectionHeading] 那枚「朱印」竖条**横过来**的同一母题 —— 无边框、
/// 无底色,不和分区标题、卡片抢视觉,贴在毛玻璃标题栏下沿正好连成一体。
///
/// 语义上与 [AppFilterChip] 刻意分开:**切内容视图**(书架的漫画/小说/番剧、发现页的
/// 内容档)用它;**加筛选条件**(地区/进度/排序)用描边 chip。别拿 chip 当 tab 使。
/// 自带 [preferredSize],可直接塞进 `GlassTitleBar(bottom:)` / `AppBar(bottom:)`。
class AppUnderlineTabs<T> extends StatelessWidget implements PreferredSizeWidget {
  const AppUnderlineTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.fontSize = 14,
  });

  final List<AppUnderlineTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onSelected;
  final EdgeInsetsGeometry padding;
  final double fontSize;

  /// 条高。给得比内容宽裕(14pt 中文 ≈ 20 + 间距 + 下划线 ≈ 30),
  /// 富余留给系统字体放大 —— 内容贴底排,多出来的空间落在标题那一侧。
  @override
  Size get preferredSize => Size.fromHeight(fontSize * 2.2 + 14);

  @override
  Widget build(BuildContext context) {
    // 档多 / 字号放大也不溢出;桌面横向滚动条关掉(矮条上的滚动条会压住下划线)。
    //
    // width: infinity 不能省 —— 横向 SingleChildScrollView 在**松约束**下会缩到内容宽
    // (viewport 取 constraints.constrain(child.size)),而 AppBar 把 bottom 放进一个
    // crossAxisAlignment.center 的 Column,于是整条 tab 会被居中。撑满才靠左。
    return SizedBox(
      width: double.infinity,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < tabs.length; i++) ...[
                if (i > 0) const SizedBox(width: 22),
                _Tab<T>(
                  tab: tabs[i],
                  selected: tabs[i].value == selected,
                  fontSize: fontSize,
                  height: preferredSize.height,
                  onTap: () => onSelected(tabs[i].value),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab<T> extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    required this.fontSize,
    required this.height,
    required this.onTap,
  });

  final AppUnderlineTab<T> tab;
  final bool selected;
  final double fontSize;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = selected ? p.accent : p.textMuted;
    final duration = LibraryStore.animationsEnabled
        ? const Duration(milliseconds: 200)
        : Duration.zero;
    return GestureDetector(
      key: tab.tabKey,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        // IntrinsicWidth:让下划线正好等宽于上面那行文字(stretch 取其固有宽)。
        // 定高 + 贴底:条高给得宽裕,系统字体放大时富余从上面吃掉,下划线始终贴着底边,
        // 也就不会顶破 preferredSize。
        child: SizedBox(
          height: height,
          child: IntrinsicWidth(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (tab.icon != null) ...[
                        Icon(tab.icon, size: fontSize + 1, color: fg),
                        const SizedBox(width: 5),
                      ],
                      AnimatedDefaultTextStyle(
                        duration: duration,
                        style: TextStyle(
                          color: fg,
                          fontSize: fontSize,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                        child: Text(tab.label),
                      ),
                      if (tab.count != null) ...[
                        const SizedBox(width: 6),
                        AnimatedDefaultTextStyle(
                          duration: duration,
                          style: TextStyle(
                            color: selected
                                ? p.accent.withValues(alpha: 0.7)
                                : p.textMuted.withValues(alpha: 0.65),
                            fontSize: fontSize - 3,
                            fontWeight: FontWeight.w700,
                          ),
                          child: Text('${tab.count}'),
                        ),
                      ],
                    ],
                  ),
                ),
                _Underline(active: selected, duration: duration),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 朱印竖条横过来:accent 渐变短横,从中间抻开 / 收回。
class _Underline extends StatelessWidget {
  const _Underline({required this.active, required this.duration});

  final bool active;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: active ? 1 : 0),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scaleX: t, alignment: Alignment.center, child: child),
      ),
      child: Container(
        height: 2.5,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [p.accent, p.accent.withValues(alpha: 0.45)],
          ),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
