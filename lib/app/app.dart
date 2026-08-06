import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../core/downloads/download_coordinator.dart';
import '../core/downloads/download_policy.dart';
import '../core/downloads/download_task_repository.dart';
import '../core/log/app_log.dart';
import 'auth_store.dart';
import 'download_coordinator_scope.dart';
import 'download_store.dart';
import 'legacy_download_migrator.dart';
import 'library_store.dart';
import 'novel_library_store.dart';
import 'novel_download_store.dart';
import 'source_controller.dart';
import '../core/source/source_repository.dart';
import '../core/sync/sync_controller.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import '../features/common/app_background.dart';
import '../features/common/ui_scale.dart';
import '../features/shell/home_shell.dart';
import '../features/shell/splash_gate.dart';

/// 应用根。持有三主题状态(ThemeController),经 ThemeScope 下发,
/// 主题切换在设置页;主界面是底部导航外壳。
class App extends StatefulWidget {
  const App({super.key, this.downloadCoordinator});

  final DownloadCoordinator? downloadCoordinator;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final ThemeController _theme = ThemeController(AppThemeVariant.oled);
  final SourceController _source = SourceController();
  final LibraryStore _library = LibraryStore();
  final NovelLibraryStore _novelLibrary = NovelLibraryStore();
  final DownloadStore _downloads = DownloadStore();
  final NovelDownloadStore _novelDownloads = NovelDownloadStore();
  final AuthStore _auth = AuthStore();
  late final DownloadCoordinator _downloadCoordinator;
  late final bool _ownsDownloadCoordinator;

  @override
  void initState() {
    super.initState();
    _ownsDownloadCoordinator = widget.downloadCoordinator == null;
    _downloadCoordinator = widget.downloadCoordinator ??
        DownloadCoordinator(
          repository: FileDownloadTaskRepository(
            rootProvider: _downloadManagerRoot,
          ),
          environment: _initialDownloadEnvironment,
          settings: DownloadPolicySettings.new,
        );
    unawaited(_loadDownloadState());
    _theme.load(); // 读回保存的主题变体(OLED/Dark/Light),否则每次重启回到默认
    _source.load(); // 读回上次选中的漫画源,否则重启回到默认第一个源
    // 书架读档完成后:先挂「变化后自动上传」的监听(基线=上次持久化的,
    // 能补传上次退出前漏掉的变化),再跑启动自动同步(源仓已在 main 里 load 好)。
    Future.wait([
      _library.load(),
      _novelLibrary.load(),
    ]).then((_) async {
      if (!mounted) return;
      final sync = SyncController.instance;
      await sync.attachAutoUpload(
        _library,
        _novelLibrary,
        SourceRepository.instance,
      );
      if (!mounted) return;
      await sync.autoSyncOnStart(
        _library,
        _novelLibrary,
        SourceRepository.instance,
      );
    });
    _auth.load(); // 读回各源登录 token,注入源引擎(SourceAuth)供需登录的源用
  }

  Future<void> _loadDownloadState() async {
    try {
      await Future.wait([
        _downloadCoordinator.load(),
        _downloads.load(),
        _novelDownloads.load(),
      ]);
    } catch (error) {
      AppLog.i.err(
        LogCat.download,
        '下载状态加载失败',
        detail: '$error',
      );
      return;
    }
    if (!mounted) return;
    try {
      await LegacyDownloadMigrator.migrate(
        coordinator: _downloadCoordinator,
        mangaDownloads: _downloads,
        novelDownloads: _novelDownloads,
      );
    } catch (error) {
      AppLog.i.err(
        LogCat.download,
        '旧下载记录迁移失败，继续使用原索引',
        detail: '$error',
      );
    }
    if (!mounted) return;
    _downloadCoordinator.registerExecutor(_downloads);
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: _theme,
      child: SourceScope(
        controller: _source,
        child: LibraryScope(
          store: _library,
          child: NovelLibraryScope(
            store: _novelLibrary,
            child: DownloadCoordinatorScope(
              coordinator: _downloadCoordinator,
              child: DownloadScope(
                store: _downloads,
                child: NovelDownloadScope(
                  store: _novelDownloads,
                  child: AuthScope(
                    store: _auth,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([
                        _theme,
                        _library.controlRadiusVN,
                        _library.uiScaleVN,
                        _library.uiFontVN,
                        _library.uiLocaleVN,
                        _novelLibrary.preferencesNotifier,
                      ]),
                      builder: (context, _) {
                        const desktop = {
                          TargetPlatform.windows,
                          TargetPlatform.linux,
                          TargetPlatform.macOS,
                        };
                        final isDesktop =
                            desktop.contains(defaultTargetPlatform);
                        return MaterialApp(
                          title: 'Dream Manga Reader',
                          debugShowCheckedModeBanner: false,
                          // 多语言:gen-l10n 生成的委托 + 支持语言列表(含 Material 组件本地化)。
                          locale: _library.uiLocale.toLocale(),
                          supportedLocales: AppLocalizations.supportedLocales,
                          localizationsDelegates:
                              AppLocalizations.localizationsDelegates,
                          theme: buildTheme(_theme.variant,
                              controlRadius: _library.controlRadius,
                              // 字体只在桌面平台生效
                              fontFamily: isDesktop ? _library.uiFont : ''),
                          home: const SplashGate(child: HomeShell()),
                          // 桌面(尤其 Windows)无障碍桥有 AXTree bug:每加载一张图就触发一次
                          // 语义更新、应用失败刷屏,严重时卡死。漫画阅读器桌面端不需要无障碍,
                          // 整体关掉语义树彻底规避;手机端保留。ExcludeSemantics 只去 a11y。
                          builder: (context, child) {
                            var w = child ?? const SizedBox.shrink();
                            if (isDesktop) w = ExcludeSemantics(child: w);
                            // 全局背景垫在所有页面之后(透明 scaffold 才能透出)。
                            w = AppBackground(child: w);
                            // 桌面界面缩放:整体等比缩放(文字/图标/间距一起),并按缩放后的
                            // 画布重新布局——不像 textScaler 只放大文字会撑破固定高度的布局。
                            if (isDesktop && _library.uiScale != 1.0) {
                              w = UiScale(scale: _library.uiScale, child: w);
                            }
                            return w;
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _theme.dispose();
    _source.dispose();
    _library.dispose();
    _novelLibrary.dispose();
    _downloads.dispose();
    _novelDownloads.dispose();
    if (_ownsDownloadCoordinator) _downloadCoordinator.dispose();
    _auth.dispose();
    super.dispose();
  }
}

Future<String> _downloadManagerRoot() async {
  final support = await getApplicationSupportDirectory();
  return '${support.path}${Platform.pathSeparator}download-manager';
}

Future<DownloadEnvironment> _initialDownloadEnvironment() async {
  return const DownloadEnvironment(
    connected: true,
    wifi: true,
    metered: false,
    roaming: false,
    batteryLow: false,
    storageAvailable: true,
    freeBytes: 0x3FFFFFFFFFFFFFFF,
  );
}
