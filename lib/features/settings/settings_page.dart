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
import '../../core/l10n/app_locale.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/net/app_proxy.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/source_repository.dart';
import '../../core/platform/system_fonts.dart';
import '../common/transitions.dart';
import '../../core/update/update_service.dart';
import '../../ui/ui.dart';
import 'about_page.dart';
import 'font_picker_sheet.dart';
import 'log_page.dart';
import 'proxy_settings_page.dart';
import 'source_management_page.dart';
import 'sync_page.dart';
import 'translate_settings_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
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
        title: Text(l10n.settingsTitle,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: EntranceSlide(
        begin: const Offset(0, 0.06),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: AppScrollView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 40 + bottomInset),
        children: [
          _group(l10n.secAppearance, [
            _languageRow(context, l10n, lib),
            _rowCard(AppSegmentedRow<AppThemeVariant>(
              icon: Icons.palette_rounded,
              title: l10n.theme,
              segments: [
                for (final v in AppThemeVariant.values)
                  ButtonSegment(value: v, label: Text(v.shortLabel)),
              ],
              selected: {theme.variant},
              onSelectionChanged: (s) => theme.variant = s.first,
            )),
            _sliderRow(Icons.crop_square_rounded, l10n.controlRadius,
                lib.controlRadius, 0, 28, 28, (v) => lib.controlRadius = v),
            _switch(
                Icons.animation_rounded,
                l10n.enableAnimations,
                l10n.enableAnimationsSub,
                lib.enableAnimations,
                (v) => lib.enableAnimations = v),
            _switch(
                Icons.swipe_vertical_rounded,
                l10n.scrollAnimations,
                l10n.scrollAnimationsSub,
                lib.scrollAnimations,
                (v) => lib.scrollAnimations = v),
          ]),
          if (isDesktop)
            _group(l10n.secDesktop, [
              _sliderRow(Icons.zoom_out_map_rounded, l10n.uiScale, lib.uiScale,
                  0.7, 1.6, 18, (v) => lib.uiScale = v, pct: true),
              if (isWindows) _fontSelector(context, p, lib),
            ]),
          _group(l10n.secReading, [
            _rowCard(AppSegmentedRow<ReaderMode>(
              icon: Icons.menu_book_rounded,
              title: l10n.reader_mode,
              segments: [
                ButtonSegment(
                    value: ReaderMode.paged,
                    label: Text(l10n.reader_modeNormal),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 15)),
                ButtonSegment(
                    value: ReaderMode.pagedRtl,
                    label: Text(l10n.reader_modeManga),
                    icon: const Icon(Icons.arrow_back_rounded, size: 15)),
                ButtonSegment(
                    value: ReaderMode.webtoon,
                    label: Text(l10n.reader_modeWebtoon),
                    icon: const Icon(Icons.arrow_downward_rounded, size: 15)),
              ],
              selected: {lib.readerMode},
              onSelectionChanged: (s) => lib.readerMode = s.first,
            )),
            _sliderRow(Icons.download_for_offline_rounded, l10n.set_preloadPages,
                lib.preload.toDouble(), 0, 8, 8, (v) => lib.preload = v.round()),
            _switch(Icons.auto_stories_rounded, l10n.set_doublePage,
                l10n.set_doublePageSub,
                lib.doublePage, (v) => lib.doublePage = v),
            _switch(Icons.zoom_in_rounded, l10n.set_doubleTapZoom,
                l10n.set_doubleTapZoomSub,
                lib.doubleTapZoom, (v) => lib.doubleTapZoom = v),
            _switch(Icons.pin_rounded, l10n.set_showPageNumber,
                l10n.set_showPageNumberSub,
                lib.showPageNumber, (v) => lib.showPageNumber = v),
          ]),
          _group(l10n.secBookshelf, [
            _rowCard(AppSegmentedRow<int>(
              icon: Icons.grid_view_rounded,
              title: l10n.set_gridColumns,
              subtitle: l10n.set_gridColumnsSub,
              segments: [
                ButtonSegment(value: 0, label: Text(l10n.set_colAuto)),
                const ButtonSegment(value: 3, label: Text('3')),
                const ButtonSegment(value: 4, label: Text('4')),
                const ButtonSegment(value: 5, label: Text('5')),
                const ButtonSegment(value: 6, label: Text('6')),
              ],
              selected: {lib.gridColumns},
              onSelectionChanged: (s) => lib.gridColumns = s.first,
            )),
            _sliderRow(Icons.rounded_corner_rounded, l10n.set_coverRadius,
                lib.coverRadius, 0, 24, 12, (v) => lib.coverRadius = v),
            _rowCard(AppSegmentedRow<FeedLayout>(
              icon: Icons.dashboard_customize_rounded,
              title: l10n.set_coverLayout,
              subtitle: l10n.set_coverLayoutSub,
              segments: [
                ButtonSegment(
                    value: FeedLayout.masonry,
                    label: Text(l10n.set_layoutMasonry)),
                ButtonSegment(
                    value: FeedLayout.grid, label: Text(l10n.set_layoutGrid)),
                ButtonSegment(
                    value: FeedLayout.list, label: Text(l10n.set_layoutList)),
              ],
              selected: {lib.feedLayout},
              onSelectionChanged: (s) => lib.feedLayout = s.first,
            )),
            _switch(
                Icons.source_rounded,
                l10n.set_showSourcePicker,
                l10n.set_showSourcePickerSub,
                lib.showSourcePicker,
                (v) => lib.showSourcePicker = v),
          ]),
          _group(l10n.set_secBackground, [
            _tile(
              Icons.wallpaper_rounded,
              l10n.set_bgImage,
              lib.bgImage.isEmpty
                  ? l10n.set_bgImageEmpty
                  : lib.bgImage.split(Platform.pathSeparator).last,
              () => _pickBg(lib),
            ),
            if (lib.bgImage.isNotEmpty) ...[
              _rowCard(AppListRow(
                icon: Icons.close_rounded,
                title: l10n.set_clearBg,
                onTap: () => lib.bgImage = '',
                showChevron: false,
                contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              )),
              _sliderRow(Icons.blur_on_rounded, l10n.set_bgBlur, lib.bgBlur, 0,
                  40, 40, (v) => lib.bgBlur = v),
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
                child: Row(
                  children: [
                    Icon(Icons.palette_rounded, size: 16, color: p.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(l10n.set_bgTintHint,
                          style: TextStyle(color: p.textMuted, fontSize: 11)),
                    ),
                  ],
                ),
              ),
              _sliderRow(Icons.opacity_rounded, l10n.set_bgTintAlpha,
                  lib.bgTintAlpha, 0, 1, 20, (v) => lib.bgTintAlpha = v,
                  pct: true),
              _sliderRow(Icons.gradient_rounded, l10n.set_detailTint,
                  lib.detailTintStrength, 0, 1, 20,
                  (v) => lib.detailTintStrength = v, pct: true),
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
                child: Text(l10n.set_detailTintHint,
                    style: TextStyle(color: p.textMuted, fontSize: 11)),
              ),
              _switch(
                  Icons.auto_stories_rounded,
                  l10n.set_readerBg,
                  l10n.set_readerBgSub,
                  lib.readerBackground,
                  (v) => lib.readerBackground = v),
            ],
          ]),
          _group(l10n.set_secNetwork, [
            _tile(
              Icons.vpn_lock_rounded,
              l10n.proxy_title,
              l10n.set_proxyCurrent(
                  AppProxy.current ?? l10n.proxy_direct, AppProxy.sourceLabel),
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProxySettingsPage())),
            ),
            _tile(
              Icons.translate_rounded,
              l10n.trans_title,
              l10n.set_translateSubtitle(lib.translateProvider.label),
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const TranslateSettingsPage())),
            ),
            _switch(
                Icons.manage_search_rounded,
                l10n.set_translateSearch,
                l10n.set_translateSearchSub,
                lib.translateSearch,
                (v) => lib.translateSearch = v),
          ]),
          _group(l10n.set_secData, [
            _tile(
                Icons.source_rounded,
                l10n.srcmgmt_title,
                l10n.set_srcMgmtSub,
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SourceManagementPage()))),
            _tile(Icons.backup_rounded, l10n.set_backup, l10n.set_backupSub,
                () => _backup(context, lib)),
            _tile(Icons.cloud_sync_rounded, l10n.set_sync,
                l10n.set_syncSub,
                () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SyncPage()))),
            _tile(Icons.cleaning_services_rounded, l10n.set_clearCache,
                l10n.set_clearCacheSub,
                () => _showCacheSheet(context)),
          ]),
          _group(l10n.set_secUpdate, [
            _switch(Icons.system_update_rounded, l10n.set_autoCheckUpdate,
                l10n.set_autoCheckUpdateSub,
                lib.autoCheckUpdate, (v) => lib.autoCheckUpdate = v),
            _switch(Icons.science_rounded, l10n.set_includeBeta,
                l10n.set_includeBetaSub,
                lib.updateIncludeBeta, (v) => lib.updateIncludeBeta = v),
            _tile(Icons.refresh_rounded, l10n.set_checkNow,
                l10n.set_currentVersion(AppInfo.version),
                () => _checkUpdate(context, lib)),
          ]),
          _group(l10n.secOther, [
            _tile(
              Icons.receipt_long_rounded,
              l10n.log_title,
              l10n.set_logSub,
              () => Navigator.of(context).push(appRoute(const LogPage())),
            ),
            _tile(
              Icons.info_outline_rounded,
              l10n.about,
              '${AppInfo.name} · v${AppInfo.version}',
              () => Navigator.of(context).push(
                  appRoute(const AboutPage())),
            ),
          ]),
        ],
        ),
        ),
      ),
    );
  }

  Future<void> _backup(BuildContext context, LibraryStore lib) async {
    final path = await backupPath();
    if (!context.mounted) return;
    final p = context.palette;
    final l10n = context.l10n;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.set_backup),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.set_backupDialogBody,
                style: TextStyle(color: p.textMuted, fontSize: 12)),
            const SizedBox(height: 10),
            SelectableText(path,
                style: TextStyle(color: p.textPrimary, fontSize: 11.5)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(l10n.close)),
          TextButton(
            onPressed: () async {
              final ok = await importBackup(lib);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                showAppNotify(
                    context, ok ? l10n.set_restored : l10n.set_backupNotFound,
                    kind: ok ? AppNotifyKind.success : AppNotifyKind.error);
              }
            },
            child: Text(l10n.set_restore),
          ),
          FilledButton(
            onPressed: () async {
              final out = await exportBackup(lib);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                showAppNotify(context, l10n.set_exported(out),
                    kind: AppNotifyKind.success);
              }
            },
            child: Text(l10n.set_export),
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
    showAppNotify(context, context.l10n.set_checkingUpdate,
        icon: Icons.sync_rounded, duration: const Duration(seconds: 6));
    final info = await UpdateService.check(includeBeta: lib.updateIncludeBeta);
    if (!context.mounted) return;
    if (info == null) {
      showAppNotify(context, context.l10n.set_upToDate,
          kind: AppNotifyKind.success);
    } else {
      await showUpdateDialog(context, info);
    }
  }

  // 语言选择行:点开弹出四语单选(各语言用自身写法标注)。本机设置,不随云同步。
  Widget _languageRow(
          BuildContext context, AppLocalizations l10n, LibraryStore lib) =>
      _rowCard(AppSelectRow(
        icon: Icons.translate_rounded,
        title: l10n.language,
        subtitle: l10n.languageSub,
        value: lib.uiLocale.label,
        onTap: () async {
          final picked = await showAppSheet<AppLocale>(
            context,
            title: l10n.language,
            showCloseButton: true,
            body: (ctx, setSheet) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final loc in AppLocale.values) ...[
                  AppSelectableRow(
                    title: loc.label,
                    selected: loc == lib.uiLocale,
                    onTap: () => Navigator.of(ctx).pop(loc),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          );
          if (picked != null) lib.uiLocale = picked;
        },
      ));

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
    final label =
        lib.uiFont.isEmpty ? context.l10n.fontpick_systemDefault : lib.uiFont;
    return _rowCard(AppSelectRow(
      icon: Icons.font_download_rounded,
      title: context.l10n.font,
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
          title: context.l10n.chooseFont,
          trailingText: context.l10n.fontpick_countN(fonts.length),
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
        title: context.l10n.set_clearCache,
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
    final l10n = context.l10n;
    // 外壳(圆角/SafeArea/内边距/标题「清理缓存」)由 showAppSheet 提供,这里只出内容。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.set_cacheBody,
            style: TextStyle(color: p.textMuted, fontSize: 12)),
        const SizedBox(height: 14),
        _cacheRow(p, Icons.image_rounded, l10n.set_imgCache, l10n.set_imgCacheSub,
            _fmt(_imgBytes),
            _busy
                ? null
                : () => _clear(clearImageCache, l10n.set_imgCacheCleared)),
        const SizedBox(height: 8),
        _cacheRow(p, Icons.dataset_rounded, l10n.set_srcCache,
            l10n.set_srcCacheSub, _fmt(_srcBytes),
            _busy
                ? null
                : () => _clear(SourceRepository.instance.clearCache,
                    l10n.set_srcCacheCleared)),
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
            TextButton(onPressed: onClear, child: Text(context.l10n.set_clean)),
          ],
        ),
      );
}
