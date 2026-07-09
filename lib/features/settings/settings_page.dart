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
import 'sync_page.dart';
import 'translate_settings_page.dart';

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
          _group('外观', [
            _rowCard(AppSegmentedRow<AppThemeVariant>(
              icon: Icons.palette_rounded,
              title: '主题',
              segments: [
                for (final v in AppThemeVariant.values)
                  ButtonSegment(value: v, label: Text(v.shortLabel)),
              ],
              selected: {theme.variant},
              onSelectionChanged: (s) => theme.variant = s.first,
            )),
            _sliderRow(Icons.crop_square_rounded, '控件圆角', lib.controlRadius,
                0, 28, 28, (v) => lib.controlRadius = v),
            _switch(
                Icons.animation_rounded,
                '开启动画',
                '入场 / 页面切换 / 翻页等动画;关掉更省电、更跟手',
                lib.enableAnimations,
                (v) => lib.enableAnimations = v),
            _switch(
                Icons.swipe_vertical_rounded,
                '滚动动画',
                '列表滚入淡入/滑入 + 桌面滚轮平滑滚动(受「开启动画」总开关约束)',
                lib.scrollAnimations,
                (v) => lib.scrollAnimations = v),
          ]),
          if (isDesktop)
            _group('桌面', [
              _sliderRow(Icons.zoom_out_map_rounded, '界面缩放', lib.uiScale, 0.7,
                  1.6, 18, (v) => lib.uiScale = v, pct: true),
              if (isWindows) _fontSelector(context, p, lib),
            ]),
          _group('阅读', [
            _rowCard(AppSegmentedRow<ReaderMode>(
              icon: Icons.menu_book_rounded,
              title: '阅读模式',
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
              onSelectionChanged: (s) => lib.readerMode = s.first,
            )),
            _sliderRow(Icons.download_for_offline_rounded, '预加载后续页',
                lib.preload.toDouble(), 0, 8, 8, (v) => lib.preload = v.round()),
            _switch(Icons.auto_stories_rounded, '双页并排', '横屏翻页模式下左右并排显示两页',
                lib.doublePage, (v) => lib.doublePage = v),
            _switch(Icons.zoom_in_rounded, '双击缩放', '阅读时双击放大 / 还原',
                lib.doubleTapZoom, (v) => lib.doubleTapZoom = v),
            _switch(Icons.pin_rounded, '显示页码', '阅读时在角落显示 当前页 / 总页',
                lib.showPageNumber, (v) => lib.showPageNumber = v),
          ]),
          _group('书架', [
            _rowCard(AppSegmentedRow<int>(
              icon: Icons.grid_view_rounded,
              title: '每行列数',
              subtitle: '封面每行列数 · 自动=按窗宽',
              segments: const [
                ButtonSegment(value: 0, label: Text('自动')),
                ButtonSegment(value: 3, label: Text('3')),
                ButtonSegment(value: 4, label: Text('4')),
                ButtonSegment(value: 5, label: Text('5')),
                ButtonSegment(value: 6, label: Text('6')),
              ],
              selected: {lib.gridColumns},
              onSelectionChanged: (s) => lib.gridColumns = s.first,
            )),
            _sliderRow(Icons.rounded_corner_rounded, '封面圆角', lib.coverRadius,
                0, 24, 12, (v) => lib.coverRadius = v),
            _switch(
                Icons.source_rounded,
                '显示源选择器',
                '关掉(默认)→ 发现页 / 书架直接用「混合 · 全部源」,不显示源选择器',
                lib.showSourcePicker,
                (v) => lib.showSourcePicker = v),
          ]),
          _group('背景', [
            _tile(
              Icons.wallpaper_rounded,
              '背景图片',
              lib.bgImage.isEmpty
                  ? '未设置 · 点击选择一张图片'
                  : lib.bgImage.split(Platform.pathSeparator).last,
              () => _pickBg(lib),
            ),
            if (lib.bgImage.isNotEmpty) ...[
              _rowCard(AppListRow(
                icon: Icons.close_rounded,
                title: '清除背景图',
                onTap: () => lib.bgImage = '',
                showChevron: false,
                contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              )),
              _sliderRow(Icons.blur_on_rounded, '背景模糊', lib.bgBlur, 0, 40, 40,
                  (v) => lib.bgBlur = v),
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
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
              _sliderRow(Icons.opacity_rounded, '混合强度', lib.bgTintAlpha, 0, 1,
                  20, (v) => lib.bgTintAlpha = v, pct: true),
              _sliderRow(Icons.gradient_rounded, '详情页融合',
                  lib.detailTintStrength, 0, 1, 20,
                  (v) => lib.detailTintStrength = v, pct: true),
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
                child: Text('详情页背景融入封面主题色的强度 · 越低越接近底色',
                    style: TextStyle(color: p.textMuted, fontSize: 11)),
              ),
              _switch(
                  Icons.auto_stories_rounded,
                  '阅读器显示背景',
                  '阅读时也透出全局背景(默认关,专注阅读)',
                  lib.readerBackground,
                  (v) => lib.readerBackground = v),
            ],
          ]),
          _group('网络', [
            _tile(
              Icons.vpn_lock_rounded,
              '网络代理',
              '当前:${AppProxy.current ?? '直连'} · ${AppProxy.sourceLabel}',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProxySettingsPage())),
            ),
            _tile(
              Icons.translate_rounded,
              '翻译',
              '搜索栏翻译 · 当前:${lib.translateProvider.label}',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const TranslateSettingsPage())),
            ),
          ]),
          _group('数据', [
            _tile(
                Icons.source_rounded,
                '源管理',
                '启用/禁用漫画源',
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SourceManagementPage()))),
            _tile(Icons.backup_rounded, '备份与恢复', '导出/导入书架与进度',
                () => _backup(context, lib)),
            _tile(Icons.cloud_sync_rounded, '云同步 (WebDAV)',
                '收藏 / 进度 / 设置 / 源 跨设备同步',
                () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SyncPage()))),
            _tile(Icons.cleaning_services_rounded, '清理缓存', '查看占用 · 分类清理',
                () => _showCacheSheet(context)),
          ]),
          _group('更新', [
            _switch(Icons.system_update_rounded, '自动检查更新', '启动时后台检查有无新版本',
                lib.autoCheckUpdate, (v) => lib.autoCheckUpdate = v),
            _switch(Icons.science_rounded, '包含测试版', '检查时把 Beta / RC 预发布也算进来',
                lib.updateIncludeBeta, (v) => lib.updateIncludeBeta = v),
            _tile(Icons.refresh_rounded, '立即检查更新',
                '当前 v${AppInfo.version}', () => _checkUpdate(context, lib)),
          ]),
          _group('其它', [
            _tile(
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
    return _rowCard(AppSelectRow(
      icon: Icons.font_download_rounded,
      title: '字体',
      value: label,
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      // 用选中字体自身渲染右侧值,一眼看清字形。
      valueStyle: TextStyle(
        fontFamily: lib.uiFont.isEmpty ? null : lib.uiFont,
        fontFamilyFallback: kFontFallback,
        color: p.textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
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
    ));
  }

  // 单个设置条目的独立描边卡(参照「开启动画」开关行:横向 + 边框)。
  // 每行自成一张 surface + line 描边卡,分组不再套外层大卡。
  Widget _rowCard(Widget child, {EdgeInsetsGeometry padding = EdgeInsets.zero}) =>
      AppCard(width: double.infinity, padding: padding, child: child);

  // 复用 lib/ui 的 AppSliderRow(设置页/阅读设置共用同一形状),自带描边卡。
  Widget _sliderRow(IconData icon, String label, double value,
          double min, double max, int div, ValueChanged<double> onChanged,
          {bool pct = false}) =>
      _rowCard(
        AppSliderRow(
          icon: icon,
          label: label,
          value: value,
          min: min,
          max: max,
          divisions: div,
          onChanged: onChanged,
          pct: pct,
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      );

  // 开关行(复用 AppSwitchRow),自带描边卡。
  Widget _switch(IconData icon, String title, String? sub,
          bool value, ValueChanged<bool> onChanged) =>
      _rowCard(AppSwitchRow(
        icon: icon,
        title: title,
        subtitle: sub,
        value: value,
        onChanged: onChanged,
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      ));

  /// 一个设置分类:小标题 + 一列「各自描边」的条目卡(参照「开启动画」样式)。
  Widget _group(String label, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 10),
              child: AppSectionHeading(label),
            ),
            // 每个条目一张独立描边卡,相邻卡补 8px 竖向间距。
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              children[i],
            ],
          ],
        ),
      );

  // 可点条目行(复用 AppListRow;onTap 非空自动补右箭头),自带描边卡。
  Widget _tile(IconData icon, String title, String? subtitle,
          VoidCallback onTap) =>
      _rowCard(AppListRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        subtitleMaxLines: 1,
        onTap: onTap,
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      ));

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
