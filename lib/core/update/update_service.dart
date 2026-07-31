import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_info.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../ui/ui.dart';
import '../l10n/app_strings.dart';
import '../log/app_log.dart';
import 'update_asset_selector.dart';
import 'update_downloader.dart';
import 'update_installer.dart';
import 'update_models.dart';
import 'update_release_client.dart';
import 'update_resolver.dart';

enum UpdateCheckState { updateAvailable, upToDate, failed }

class UpdateCheckResult {
  const UpdateCheckResult(this.state, {this.candidate, this.error});

  final UpdateCheckState state;
  final UpdateCandidate? candidate;
  final UpdateResolutionException? error;
}

/// 检查 Gitee 和 GitHub Releases 有没有比当前更新的版本。
class UpdateService {
  UpdateService._();

  /// 查最新版本。[includeBeta]=true 时把预发布(-beta/-rc/-alpha)也算进来。
  /// **当前若本身是预发布,自动包含预发布**——beta 用户就该收到 beta 更新。
  /// 网络或来源错误会明确返回 [UpdateCheckState.failed]，不会伪装成最新版。
  static Future<UpdateCheckResult> check({
    bool includeBeta = false,
    UpdateSource preferredSource = UpdateSource.gitee,
  }) async {
    AppLog.i.info(LogCat.update, '检查更新…${includeBeta ? '(含测试版)' : ''}');
    try {
      final candidate = await UpdateResolver(
        gitee: GiteeReleaseClient(),
        github: GitHubReleaseClient(),
      ).resolve(
        currentVersion: AppInfo.version,
        preferred: preferredSource,
        includeBeta: includeBeta,
      );
      if (candidate == null) {
        AppLog.i.info(LogCat.update, '已是最新版 · v${AppInfo.version}');
        return const UpdateCheckResult(UpdateCheckState.upToDate);
      }
      AppLog.i.success(
        LogCat.update,
        '发现新版本 ${candidate.tag}(当前 v${AppInfo.version}，${candidate.source.displayName})',
      );
      for (final warning in candidate.warnings) {
        AppLog.i.warn(LogCat.update, warning);
      }
      return UpdateCheckResult(
        UpdateCheckState.updateAvailable,
        candidate: candidate,
      );
    } on UpdateResolutionException catch (error) {
      AppLog.i.err(LogCat.update, '检查更新失败', detail: '$error');
      return UpdateCheckResult(UpdateCheckState.failed, error: error);
    }
  }

  /// 当前 tag/版本是否为预发布(带 -beta/-rc/-alpha 后缀)。
  static bool isPrerelease(String value) =>
      UpdateVersion.tryParse(value)?.isPrerelease ?? false;

  /// 语义化版本比较:先比 major.minor.patch;base 相等时正式版 > 预发布,预发布之间
  /// 按标识符逐段比(beta.3 < beta.4、beta.9 < beta.10、alpha < beta)。a>b 正、a<b 负、相等 0。
  static int compareVersions(String a, String b) =>
      UpdateVersion.parse(a).compareTo(UpdateVersion.parse(b));
}

typedef UpdateDownloadCallback = Future<File> Function(
  ResolvedUpdateAsset asset, {
  required CancelToken cancelToken,
  required void Function(double progress) onProgress,
});

typedef UpdateInstallCallback = Future<void> Function(
  File package, {
  Future<void> Function()? onBeforeExit,
});

typedef UpdateManualCallback = Future<void> Function(Uri uri);

@immutable
class UpdateDialogDependencies {
  const UpdateDialogDependencies({
    required this.download,
    required this.install,
    required this.openManual,
  });

  final UpdateDownloadCallback download;
  final UpdateInstallCallback install;
  final UpdateManualCallback openManual;

  static UpdateDialogDependencies production() => UpdateDialogDependencies(
        download: (
          asset, {
          required cancelToken,
          required onProgress,
        }) =>
            UpdateDownloader().download(
          asset,
          cancelToken: cancelToken,
          onProgress: onProgress,
        ),
        install: (package, {onBeforeExit}) => UpdateInstaller.install(
          package,
          onBeforeExit: onBeforeExit,
        ),
        openManual: (uri) async {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        },
      );
}

enum _UpdateStage {
  preparing,
  idle,
  downloading,
  verifying,
  launching,
  complete,
  error,
}

/// 弹出「发现新版本」对话框并在应用内完成下载、校验和安装器启动。
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateCandidate info, {
  UpdateDialogDependencies? dependencies,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _UpdateDialog(
      info: info,
      dependencies: dependencies ?? UpdateDialogDependencies.production(),
    ),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info, required this.dependencies});

  final UpdateCandidate info;
  final UpdateDialogDependencies dependencies;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _UpdateStage _stage = _UpdateStage.preparing;
  double _progress = 0;
  ResolvedUpdateAsset? _asset;
  String? _error;
  CancelToken? _cancel;

  bool get _busy => switch (_stage) {
        _UpdateStage.downloading ||
        _UpdateStage.verifying ||
        _UpdateStage.launching =>
          true,
        _ => false,
      };

  @override
  void initState() {
    super.initState();
    _prepareAsset();
  }

  Future<void> _prepareAsset() async {
    ResolvedUpdateAsset? selected;
    if (UpdateInstaller.supported &&
        widget.info.integrity == UpdateIntegrity.manifest &&
        widget.info.manifest != null) {
      final platform =
          Platform.isWindows ? UpdatePlatform.windows : UpdatePlatform.android;
      try {
        selected = await const UpdateAssetSelector().select(
          platform: platform,
          assets: widget.info.resolveAssets(platform),
        );
      } on FormatException {
        selected = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _asset = selected;
      _stage = _UpdateStage.idle;
    });
  }

  Future<void> _startUpdate() async {
    final asset = _asset;
    if (asset == null) return;
    final cancel = _cancel = CancelToken();
    setState(() {
      _stage = _UpdateStage.downloading;
      _error = null;
      _progress = 0;
    });
    try {
      final package = await widget.dependencies.download(
        asset,
        cancelToken: cancel,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            if (p >= 1) _stage = _UpdateStage.verifying;
          });
        },
      );
      if (cancel.isCancelled) {
        if (mounted) setState(() => _stage = _UpdateStage.idle);
        return;
      }
      if (mounted) setState(() => _stage = _UpdateStage.launching);
      await widget.dependencies.install(
        package,
        onBeforeExit: () => LibraryScope.read(context).flushPending(),
      );
      if (mounted) {
        setState(() {
          _stage = _UpdateStage.complete;
        });
      }
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.type == DioExceptionType.cancel) {
          _stage = _UpdateStage.idle;
        } else {
          _error = '$e';
          _stage = _UpdateStage.error;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _stage = _UpdateStage.error;
        });
      }
    }
  }

  Future<void> _openPage() =>
      widget.dependencies.openManual(Uri.parse(widget.info.pageUrl));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final screen = MediaQuery.sizeOf(context);
    final contentWidth = (screen.width * 0.78).clamp(280.0, 480.0);
    final contentHeight = (screen.height * 0.45).clamp(220.0, 320.0);
    final sourceLabel = widget.info.source == UpdateSource.gitee
        ? l10n.update_sourceGitee
        : l10n.update_sourceGitHubFallback;
    return AlertDialog(
      backgroundColor: p.surface,
      title: Text(
        l10n.update_foundTitle(widget.info.tag),
        style: TextStyle(
            color: p.textPrimary, fontSize: 16, fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: contentWidth,
        height: contentHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              sourceLabel,
              style: TextStyle(
                color: p.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: widget.info.notes.isEmpty
                    ? Text(l10n.update_noNotes,
                        style: TextStyle(
                            color: p.textMuted, fontSize: 12.5, height: 1.5))
                    : MarkdownView(widget.info.notes),
              ),
            ),
            const SizedBox(height: 12),
            if (_busy) ...[
              LinearProgressIndicator(
                value: _progress,
                backgroundColor: p.line,
              ),
              const SizedBox(height: 8),
              Text(
                _statusText(l10n),
                style: TextStyle(color: p.textMuted, fontSize: 12),
              ),
            ] else if (_stage == _UpdateStage.complete)
              Text(
                l10n.update_installerOpened,
                style: TextStyle(color: p.textPrimary, fontSize: 12.5),
              )
            else if (_stage == _UpdateStage.error)
              Text(
                l10n.update_failed(_error ?? ''),
                style: TextStyle(color: p.statusFail, fontSize: 12),
              )
            else if (_stage == _UpdateStage.idle && _asset == null)
              Text(
                l10n.update_noCompatibleAsset,
                style: TextStyle(color: p.textMuted, fontSize: 12),
              )
            else if (_stage == _UpdateStage.preparing)
              Text(
                l10n.update_preparing,
                style: TextStyle(color: p.textMuted, fontSize: 12),
              ),
          ],
        ),
      ),
      actions: _actions(),
    );
  }

  String _statusText(AppLocalizations l10n) => switch (_stage) {
        _UpdateStage.downloading =>
          l10n.update_downloadingProgress((_progress * 100).round()),
        _UpdateStage.verifying => l10n.update_verifying,
        _UpdateStage.launching => Platform.isWindows
            ? l10n.update_launchingWindows
            : l10n.update_launchingAndroid,
        _ => '',
      };

  List<Widget> _actions() {
    final l10n = context.l10n;
    if (_stage == _UpdateStage.downloading ||
        _stage == _UpdateStage.verifying) {
      return [
        TextButton(
          key: const Key('update-cancel'),
          onPressed: () => _cancel?.cancel('user'),
          child: Text(l10n.cancel),
        ),
      ];
    }
    if (_stage == _UpdateStage.launching) return const [];
    if (_stage == _UpdateStage.complete) {
      return [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.done)),
      ];
    }
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.later),
      ),
      if (_stage == _UpdateStage.error ||
          (_stage == _UpdateStage.idle && _asset == null))
        TextButton(
          key: const Key('update-manual'),
          onPressed: _openPage,
          child: Text(l10n.goDownloadPage),
        ),
      if (_stage == _UpdateStage.idle && _asset != null)
        FilledButton(
          key: const Key('update-primary'),
          onPressed: _startUpdate,
          child: Text(l10n.update_primary),
        ),
      if (_stage == _UpdateStage.error && _asset != null)
        FilledButton(
          key: const Key('update-retry'),
          onPressed: _startUpdate,
          child: Text(l10n.retry),
        ),
    ];
  }
}
