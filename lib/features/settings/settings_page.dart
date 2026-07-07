import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_info.dart';
import '../../app/backup.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/theme_controller.dart';
import '../../core/net/app_proxy.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/source_repository.dart';
import '../../core/platform/system_fonts.dart';
import '../common/transitions.dart';
import '../../core/update/update_service.dart';
import '../../ui/ui.dart';
import 'about_page.dart';
import 'font_picker_sheet.dart';
import 'proxy_settings_page.dart';
import 'source_management_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = ThemeScope.of(context);
    final lib = LibraryScope.of(context);
    const desktop = {
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    };
    final isDesktop = desktop.contains(defaultTargetPlatform);
    // 字体枚举/选择只在 Windows 有意义(GDI 枚举 + fontFamily 解析);
    // 其他桌面平台没枚举结果,回退列表也是 Windows 字体,故只在 Windows 显示。
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    // 窄屏外壳 extendBody + 底部导航会盖住内容 → 底部留出导航高度,否则最后一项(关于)
    // 拉不到底。读顶层 context(设置页自身 Scaffold 之上),拿到被底栏遮挡的高度。
    final bottomInset = MediaQuery.of(context).padding.bottom;

    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: const Text('设置',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: EntranceSlide(
        begin: const Offset(0, 0.06),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: SmoothScroll(
        builder: (sc) => ListView(
        controller: sc,
        padding: EdgeInsets.fromLTRB(16, 8, 16, 40 + bottomInset),
        children: [
          _group(context, p, '外观', [
            SegmentedButton<AppThemeVariant>(
              segments: [
                for (final v in AppThemeVariant.values)
                  ButtonSegment(value: v, label: Text(v.shortLabel)),
              ],
              selected: {theme.variant},
              showSelectedIcon: false,
              onSelectionChanged: (s) => theme.variant = s.first,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.crop_square_rounded, size: 18, color: p.accent),
                const SizedBox(width: 8),
                Text('控件圆角',
                    style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                Expanded(
                  child: Slider(
                    value: lib.controlRadius,
                    min: 0,
                    max: 28,
                    divisions: 28,
                    label: lib.controlRadius.round().toString(),
                    onChanged: (v) => lib.controlRadius = v,
                  ),
                ),
                SizedBox(
                  width: 26,
                  child: Text(lib.controlRadius.round().toString(),
                      textAlign: TextAlign.end,
                      style: TextStyle(color: p.textMuted, fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _switch(
                p,
                Icons.animation_rounded,
                '开启动画',
                '入场 / 页面切换 / 翻页等动画;关掉更省电、更跟手',
                lib.enableAnimations,
                (v) => lib.enableAnimations = v),
            _switch(
                p,
                Icons.swipe_vertical_rounded,
                '滚动动画',
                '列表滚入淡入/滑入 + 桌面滚轮平滑滚动(受「开启动画」总开关约束)',
                lib.scrollAnimations,
                (v) => lib.scrollAnimations = v),
          ]),
          if (isDesktop)
            _group(context, p, '桌面', [
              _sliderRow(p, Icons.zoom_out_map_rounded, '界面缩放', lib.uiScale, 0.7,
                  1.6, 18, (v) => lib.uiScale = v, pct: true),
              if (isWindows) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.font_download_rounded,
                        size: 18, color: p.accent),
                    const SizedBox(width: 8),
                    Text('字体',
                        style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                _fontSelector(context, p, lib),
              ],
            ]),
          _group(context, p, '阅读', [
            SegmentedButton<ReaderMode>(
              segments: const [
                ButtonSegment(
                    value: ReaderMode.paged,
                    label: Text('普通'),
                    icon: Icon(Icons.arrow_forward_rounded, size: 15)),
                ButtonSegment(
                    value: ReaderMode.pagedRtl,
                    label: Text('日漫'),
                    icon: Icon(Icons.arrow_back_rounded, size: 15)),
                ButtonSegment(
                    value: ReaderMode.webtoon,
                    label: Text('滚动'),
                    icon: Icon(Icons.arrow_downward_rounded, size: 15)),
              ],
              selected: {lib.readerMode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => lib.readerMode = s.first,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.download_for_offline_rounded,
                    size: 18, color: p.accent),
                const SizedBox(width: 8),
                Text('预加载后续页',
                    style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                Expanded(
                  child: Slider(
                    value: lib.preload.toDouble(),
                    min: 0,
                    max: 8,
                    divisions: 8,
                    label: '${lib.preload}',
                    onChanged: (v) => lib.preload = v.round(),
                  ),
                ),
                SizedBox(
                  width: 22,
                  child: Text('${lib.preload}',
                      textAlign: TextAlign.end,
                      style: TextStyle(color: p.textMuted, fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _switch(p, Icons.auto_stories_rounded, '双页并排', '横屏翻页模式下左右并排显示两页',
                lib.doublePage, (v) => lib.doublePage = v),
            _switch(p, Icons.zoom_in_rounded, '双击缩放', '阅读时双击放大 / 还原',
                lib.doubleTapZoom, (v) => lib.doubleTapZoom = v),
            _switch(p, Icons.pin_rounded, '显示页码', '阅读时在角落显示 当前页 / 总页',
                lib.showPageNumber, (v) => lib.showPageNumber = v),
          ]),
          _group(context, p, '书架', [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('自动')),
                ButtonSegment(value: 3, label: Text('3')),
                ButtonSegment(value: 4, label: Text('4')),
                ButtonSegment(value: 5, label: Text('5')),
                ButtonSegment(value: 6, label: Text('6')),
              ],
              selected: {lib.gridColumns},
              showSelectedIcon: false,
              onSelectionChanged: (s) => lib.gridColumns = s.first,
            ),
            const SizedBox(height: 6),
            Text('封面每行列数 · 自动=按窗宽',
                style: TextStyle(color: p.textMuted, fontSize: 11)),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.rounded_corner_rounded, size: 18, color: p.accent),
                const SizedBox(width: 8),
                Text('封面圆角',
                    style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                Expanded(
                  child: Slider(
                    value: lib.coverRadius,
                    min: 0,
                    max: 24,
                    divisions: 12,
                    label: lib.coverRadius.round().toString(),
                    onChanged: (v) => lib.coverRadius = v,
                  ),
                ),
                SizedBox(
                  width: 26,
                  child: Text(lib.coverRadius.round().toString(),
                      textAlign: TextAlign.end,
                      style: TextStyle(color: p.textMuted, fontSize: 13)),
                ),
              ],
            ),
          ]),
          _group(context, p, '背景', [
            _tile(
              p,
              Icons.wallpaper_rounded,
              '背景图片',
              lib.bgImage.isEmpty
                  ? '未设置 · 点击选择一张图片'
                  : lib.bgImage.split(Platform.pathSeparator).last,
              () => _pickBg(lib),
            ),
            if (lib.bgImage.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => lib.bgImage = '',
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('清除背景图'),
                ),
              ),
              _sliderRow(p, Icons.blur_on_rounded, '背景模糊', lib.bgBlur, 0, 40, 40,
                  (v) => lib.bgBlur = v),
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 4, bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.palette_rounded, size: 16, color: p.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('混合色随主题自动 · 深色系用暗调、浅色用白调',
                          style: TextStyle(color: p.textMuted, fontSize: 11)),
                    ),
                  ],
                ),
              ),
              _sliderRow(p, Icons.opacity_rounded, '混合强度', lib.bgTintAlpha, 0, 1,
                  20, (v) => lib.bgTintAlpha = v, pct: true),
              _sliderRow(p, Icons.gradient_rounded, '详情页融合',
                  lib.detailTintStrength, 0, 1, 20,
                  (v) => lib.detailTintStrength = v, pct: true),
              Padding(
                padding: const EdgeInsets.only(left: 26, bottom: 6),
                child: Text('详情页背景融入封面主题色的强度 · 越低越接近底色',
                    style: TextStyle(color: p.textMuted, fontSize: 11)),
              ),
              _switch(
                  p,
                  Icons.auto_stories_rounded,
                  '阅读器显示背景',
                  '阅读时也透出全局背景(默认关,专注阅读)',
                  lib.readerBackground,
                  (v) => lib.readerBackground = v),
            ],
          ]),
          _group(context, p, '网络', [
            _tile(
              p,
              Icons.vpn_lock_rounded,
              '网络代理',
              '当前:${AppProxy.current ?? '直连'} · ${AppProxy.sourceLabel}',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProxySettingsPage())),
            ),
          ]),
          _group(context, p, '数据', [
            _tile(
                p,
                Icons.source_rounded,
                '源管理',
                '启用/禁用漫画源',
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SourceManagementPage()))),
            _tile(p, Icons.backup_rounded, '备份与恢复', '导出/导入书架与进度',
                () => _backup(context, lib)),
            _tile(p, Icons.cleaning_services_rounded, '清理缓存', '查看占用 · 分类清理',
                () => _showCacheSheet(context)),
          ]),
          _group(context, p, '更新', [
            _switch(p, Icons.system_update_rounded, '自动检查更新', '启动时后台检查有无新版本',
                lib.autoCheckUpdate, (v) => lib.autoCheckUpdate = v),
            _switch(p, Icons.science_rounded, '包含测试版', '检查时把 Beta / RC 预发布也算进来',
                lib.updateIncludeBeta, (v) => lib.updateIncludeBeta = v),
            _tile(p, Icons.refresh_rounded, '立即检查更新',
                '当前 v${AppInfo.version}', () => _checkUpdate(context, lib)),
          ]),
          _group(context, p, '其它', [
            _tile(
              p,
              Icons.info_outline_rounded,
              '关于',
              '${AppInfo.name} · v${AppInfo.version}',
              () => Navigator.of(context).push(
                  appRoute(const AboutPage())),
            ),
          ]),
        ],
        ),
      ),
        ),
      ),
    );
  }

  Future<void> _backup(BuildContext context, LibraryStore lib) async {
    final path = await backupPath();
    if (!context.mounted) return;
    final p = context.palette;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备份与恢复'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('导出:把收藏 / 阅读进度 / 阅读设置写到下面这个文件。恢复:从同一文件读回(异地备份就把之前的文件放回此路径)。',
                style: TextStyle(color: p.textMuted, fontSize: 12)),
            const SizedBox(height: 10),
            SelectableText(path,
                style: TextStyle(color: p.textPrimary, fontSize: 11.5)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          TextButton(
            onPressed: () async {
              final ok = await importBackup(lib);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                showAppNotify(context, ok ? '已从备份恢复' : '没找到备份文件',
                    kind: ok ? AppNotifyKind.success : AppNotifyKind.error);
              }
            },
            child: const Text('恢复'),
          ),
          FilledButton(
            onPressed: () async {
              final out = await exportBackup(lib);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                showAppNotify(context, '已导出:$out',
                    kind: AppNotifyKind.success);
              }
            },
            child: const Text('导出'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickBg(LibraryStore lib) async {
    final res = await FilePicker.pickFiles(type: FileType.image);
    final path = res?.files.single.path;
    if (path != null) lib.bgImage = path;
  }

  Future<void> _checkUpdate(BuildContext context, LibraryStore lib) async {
    showAppNotify(context, '正在检查更新…',
        icon: Icons.sync_rounded, duration: const Duration(seconds: 6));
    final info = await UpdateService.check(includeBeta: lib.updateIncludeBeta);
    if (!context.mounted) return;
    if (info == null) {
      showAppNotify(context, '已是最新版本', kind: AppNotifyKind.success);
    } else {
      await showUpdateDialog(context, info);
    }
  }

  // 系统内所有字体做成下拉:点开是可搜索的懒加载列表(每条用该字体自身渲染)。
  // 枚举失败(极少)时退回几个 Windows 常见字体,保证仍可选。
  Widget _fontSelector(BuildContext context, AppPalette p, LibraryStore lib) {
    final fonts = SystemFonts.cached.isNotEmpty
        ? SystemFonts.cached
        : const [
            'Microsoft YaHei UI',
            'Microsoft YaHei',
            'DengXian',
            'SimSun',
            'KaiTi',
            'SimHei',
          ];
    final label = lib.uiFont.isEmpty ? '系统默认' : lib.uiFont;
    return InkWell(
      borderRadius: BorderRadius.circular(context.radius),
      onTap: () async {
        final picked = await showAppSheet<String>(
          context,
          title: '选择字体',
          trailingText: '${fonts.length} 个',
          showCloseButton: true,
          resizeForKeyboard: true,
          heightFactor: 0.72,
          body: (ctx, setSheet) =>
              FontPickerSheet(fonts: fonts, current: lib.uiFont),
        );
        if (picked != null) lib.uiFont = picked;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(context.radius),
          border: Border.all(color: p.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: lib.uiFont.isEmpty ? null : lib.uiFont,
                  fontFamilyFallback: kFontFallback,
                  color: p.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down_rounded, color: p.textMuted),
          ],
        ),
      ),
    );
  }

  // 复用 lib/ui 的 AppSliderRow(设置页/阅读设置共用同一形状)。
  Widget _sliderRow(AppPalette p, IconData icon, String label, double value,
          double min, double max, int div, ValueChanged<double> onChanged,
          {bool pct = false}) =>
      AppSliderRow(
        icon: icon,
        label: label,
        value: value,
        min: min,
        max: max,
        divisions: div,
        onChanged: onChanged,
        pct: pct,
      );

  // 分组卡里用的扁平开关(复用 AppSwitchRow;卡片已提供 surface)。
  Widget _switch(AppPalette p, IconData icon, String title, String? sub,
          bool value, ValueChanged<bool> onChanged) =>
      AppSwitchRow(
        icon: icon,
        title: title,
        subtitle: sub,
        value: value,
        onChanged: onChanged,
        contentPadding: const EdgeInsets.fromLTRB(25, 0, 25, 0),
      );

  /// 一个设置分类:小标题 + 圆角卡片容器(把该类所有控件裹在一起)。
  Widget _group(BuildContext context, AppPalette p, String label,
          List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 10),
              child: AppSectionHeading(label),
            ),
            // 分组卡片(共享 AppCard)。条目左右留白由各行自带的 contentPadding 给;
            // 相邻条目补 6px 竖向间距。
            AppCard(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    children[i],
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  // 可点条目行(复用 AppListRow;onTap 非空自动补右箭头)。
  Widget _tile(AppPalette p, IconData icon, String title, String? subtitle,
          VoidCallback onTap) =>
      AppListRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        subtitleMaxLines: 1,
        onTap: onTap,
        contentPadding: const EdgeInsets.fromLTRB(25, 0, 25, 0),
      );

  Future<void> _showCacheSheet(BuildContext context) => showAppSheet<void>(
        context,
        title: '清理缓存',
        bodyPadding: const EdgeInsets.fromLTRB(20, 12, 16, 24),
        body: (ctx, setSheet) => const _CacheSheet(),
      );
}

/// 缓存清理弹层:分别展示图片缓存 / 源缓存占用,可各自清理。
class _CacheSheet extends StatefulWidget {
  const _CacheSheet();

  @override
  State<_CacheSheet> createState() => _CacheSheetState();
}

class _CacheSheetState extends State<_CacheSheet> {
  int? _imgBytes;
  int? _srcBytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final img = await imageCacheSizeBytes();
    final src = await SourceRepository.instance.cacheSizeBytes();
    if (mounted) {
      setState(() {
        _imgBytes = img;
        _srcBytes = src;
      });
    }
  }

  static String _fmt(int? b) {
    if (b == null) return '…';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _clear(Future<void> Function() op, String done) async {
    setState(() => _busy = true);
    await op();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    showAppNotify(context, done, kind: AppNotifyKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 外壳(圆角/SafeArea/内边距/标题「清理缓存」)由 showAppSheet 提供,这里只出内容。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('只清缓存,不动已下载章节与书架数据。',
            style: TextStyle(color: p.textMuted, fontSize: 12)),
        const SizedBox(height: 14),
        _cacheRow(p, Icons.image_rounded, '图片缓存', '封面 / 章节图', _fmt(_imgBytes),
            _busy ? null : () => _clear(clearImageCache, '已清理图片缓存')),
        const SizedBox(height: 8),
        _cacheRow(p, Icons.dataset_rounded, '源缓存', '清单 / 脚本 · 清后自动重拉',
            _fmt(_srcBytes),
            _busy
                ? null
                : () => _clear(
                    SourceRepository.instance.clearCache, '已清理源缓存')),
      ],
    );
  }

  Widget _cacheRow(AppPalette p, IconData icon, String title, String sub,
          String size, VoidCallback? onClear) =>
      Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: p.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.line),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: p.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title,
                          style: TextStyle(
                              color: p.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14)),
                      const SizedBox(width: 8),
                      Text(size,
                          style: TextStyle(
                              color: p.accent,
                              fontWeight: FontWeight.w700,
                              fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ],
              ),
            ),
            TextButton(onPressed: onClear, child: const Text('清理')),
          ],
        ),
      );
}
