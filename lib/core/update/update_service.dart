import 'dart:async';
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
import 'android_abi.dart';
import 'android_update_bridge.dart';
import 'update_asset_selector.dart';
import 'update_downloader.dart';
import 'update_installer.dart';
import 'update_models.dart';
import 'update_release_client.dart';
import 'update_resolver.dart';
import 'update_transfer.dart';

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

  static bool isPrerelease(String value) =>
      UpdateVersion.tryParse(value)?.isPrerelease ?? false;

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
typedef UpdateRefreshCallback = Future<UpdateCandidate?> Function(
  UpdateSource preferred,
);

@immutable
class UpdateDialogDependencies {
  factory UpdateDialogDependencies({
    required UpdateDownloadCallback download,
    required UpdateInstallCallback install,
    required UpdateManualCallback openManual,
  }) {
    return UpdateDialogDependencies.coordinator(
      coordinator: WindowsUpdateTransferCoordinator(
        download: download,
        install: install,
      ),
      refresh: _noRefresh,
      openManual: openManual,
    );
  }

  const UpdateDialogDependencies.coordinator({
    required this.coordinator,
    required this.refresh,
    required this.openManual,
  });

  final UpdateTransferCoordinator coordinator;
  final UpdateRefreshCallback refresh;
  final UpdateManualCallback openManual;

  static UpdateDialogDependencies production() {
    final UpdateTransferCoordinator coordinator;
    if (Platform.isAndroid) {
      coordinator = AndroidUpdateTransferCoordinator(AndroidUpdateBridge());
    } else {
      coordinator = WindowsUpdateTransferCoordinator(
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
      );
    }
    return UpdateDialogDependencies.coordinator(
      coordinator: coordinator,
      refresh: (preferred) async {
        final result = await UpdateService.check(
          preferredSource: preferred,
          includeBeta: true,
        );
        return result.state == UpdateCheckState.updateAvailable
            ? result.candidate
            : null;
      },
      openManual: (uri) async {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
    );
  }

  static Future<UpdateCandidate?> _noRefresh(UpdateSource _) async => null;
}

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
  bool _preparing = true;
  bool _installing = false;
  bool _complete = false;
  bool _installStarted = false;
  UpdateTransferState _transfer = const UpdateTransferState.idle();
  ResolvedUpdateAsset? _asset;
  StreamSubscription<UpdateTransferState>? _subscription;
  late UpdateCandidate _active = widget.info;

  String? get _taskKey => _asset == null
      ? null
      : '${_asset!.sha256.toLowerCase()}:${_active.version}';

  bool get _busy => _transfer.busy || _installing;

  @override
  void initState() {
    super.initState();
    _subscription = widget.dependencies.coordinator.states.listen(
      _onTransferState,
      onError: (Object error) => _onTransferState(UpdateTransferState(
        stage: UpdateTransferStage.error,
        message: sanitizeUpdateError('$error'),
      )),
    );
    _prepareAsset();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(widget.dependencies.coordinator.dispose());
    super.dispose();
  }

  Future<void> _prepareAsset() async {
    final selection = await _selectFromCandidates(widget.info);
    if (!mounted) return;
    _active = selection?.$1 ?? widget.info;
    _asset = selection?.$2;
    var restored = const UpdateTransferState.idle();
    if (_asset != null) {
      try {
        final current = await widget.dependencies.coordinator.current();
        if (current.stage == UpdateTransferStage.idle ||
            current.taskKey == _taskKey) {
          restored = current;
        }
      } catch (error) {
        restored = UpdateTransferState(
          stage: UpdateTransferStage.error,
          message: sanitizeUpdateError('$error'),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _preparing = false;
      _transfer = restored;
    });
    _maybeInstall(restored);
  }

  Future<(UpdateCandidate, ResolvedUpdateAsset)?> _selectFromCandidates(
    UpdateCandidate root,
  ) async {
    if (!UpdateInstaller.supported) return null;
    final platform =
        Platform.isWindows ? UpdatePlatform.windows : UpdatePlatform.android;
    for (final candidate in [root, ...root.alternates]) {
      if (candidate.integrity != UpdateIntegrity.manifest ||
          candidate.manifest == null) {
        continue;
      }
      final selected = await _select(candidate, platform);
      if (selected == null) continue;
      if (candidate.source != root.source) {
        AppLog.i.warn(
          LogCat.update,
          '${root.source.displayName} 没有本机架构的安装包，改用 ${candidate.source.displayName}',
        );
      }
      return (candidate, selected);
    }
    return null;
  }

  Future<ResolvedUpdateAsset?> _select(
    UpdateCandidate candidate,
    UpdatePlatform platform,
  ) async {
    const selector = UpdateAssetSelector();
    final List<ResolvedUpdateAsset> assets;
    try {
      assets = candidate.resolveAssets(platform);
    } on FormatException catch (error) {
      AppLog.i.warn(
        LogCat.update,
        '${candidate.source.displayName} 的更新清单无法绑定附件',
        detail: '$error',
      );
      return null;
    }
    try {
      return await selector.select(platform: platform, assets: assets);
    } on AndroidAbiUnavailableException catch (error) {
      AppLog.i.err(
        LogCat.update,
        '无法识别设备 ABI，改用通用安装包',
        detail: '$error',
      );
      return selector.select(
        platform: platform,
        assets: assets,
        supportedAbis: const [],
      );
    }
  }

  void _onTransferState(UpdateTransferState state) {
    if (!mounted) return;
    if (state.stage != UpdateTransferStage.idle &&
        state.taskKey != null &&
        state.taskKey != _taskKey) {
      return;
    }
    setState(() => _transfer = state);
    _maybeInstall(state);
  }

  void _maybeInstall(UpdateTransferState state) {
    if (state.stage == UpdateTransferStage.ready &&
        !widget.dependencies.coordinator.supportsBackground) {
      unawaited(_installReady());
    }
  }

  Future<void> _startUpdate() async {
    if (_transfer.errorCode == 'expired_url') {
      final refreshed = await _refreshExpiredAsset();
      if (!refreshed) return;
    }
    final asset = _asset;
    if (asset == null) return;
    _complete = false;
    _installStarted = false;
    await widget.dependencies.coordinator.start(
      candidate: _active,
      asset: asset,
    );
  }

  Future<bool> _refreshExpiredAsset() async {
    final previous = _asset;
    if (previous == null) return false;
    final refreshed = await widget.dependencies.refresh(_active.source);
    final selection =
        refreshed == null ? null : await _selectFromCandidates(refreshed);
    if (!mounted) return false;
    if (selection == null ||
        selection.$1.version != _active.version ||
        selection.$2.sha256.toLowerCase() != previous.sha256.toLowerCase()) {
      setState(() {
        _transfer = const UpdateTransferState(
          stage: UpdateTransferStage.error,
          errorCode: 'expired_url',
          message: 'The update download URL could not be refreshed.',
        );
      });
      return false;
    }
    setState(() {
      _active = selection.$1;
      _asset = selection.$2;
      _transfer = const UpdateTransferState.idle();
    });
    return true;
  }

  Future<void> _cancel() => widget.dependencies.coordinator.cancel();

  Future<void> _installReady() async {
    if (_installStarted) return;
    _installStarted = true;
    if (mounted) setState(() => _installing = true);
    try {
      await widget.dependencies.coordinator.install(
        onBeforeExit: () => LibraryScope.read(context).flushPending(),
      );
      if (mounted) {
        setState(() {
          _installing = false;
          _complete = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _installing = false;
          _installStarted = false;
          _transfer = UpdateTransferState(
            stage: UpdateTransferStage.error,
            message: sanitizeUpdateError('$error'),
          );
        });
      }
    }
  }

  Future<void> _openPage() =>
      widget.dependencies.openManual(Uri.parse(_active.pageUrl));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final screen = MediaQuery.sizeOf(context);
    final contentWidth = (screen.width * 0.78).clamp(280.0, 480.0);
    final contentHeight = (screen.height * 0.45).clamp(220.0, 320.0);
    final sourceLabel = _active.source == UpdateSource.gitee
        ? l10n.update_sourceGitee
        : l10n.update_sourceGitHubFallback;
    return AlertDialog(
      backgroundColor: p.surface,
      title: Text(
        l10n.update_foundTitle(_active.tag),
        style: TextStyle(
          color: p.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
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
                child: _active.notes.isEmpty
                    ? Text(
                        l10n.update_noNotes,
                        style: TextStyle(
                          color: p.textMuted,
                          fontSize: 12.5,
                          height: 1.5,
                        ),
                      )
                    : MarkdownView(_active.notes),
              ),
            ),
            const SizedBox(height: 12),
            if (_busy) ...[
              LinearProgressIndicator(
                value: _transfer.progress,
                backgroundColor: p.line,
              ),
              const SizedBox(height: 8),
              Text(
                _statusText(l10n),
                style: TextStyle(color: p.textMuted, fontSize: 12),
              ),
            ] else if (_complete)
              Text(
                l10n.update_installerOpened,
                style: TextStyle(color: p.textPrimary, fontSize: 12.5),
              )
            else if (_transfer.stage == UpdateTransferStage.ready)
              Text(
                l10n.update_readyNotification,
                style: TextStyle(color: p.textPrimary, fontSize: 12.5),
              )
            else if (_transfer.stage == UpdateTransferStage.error)
              Text(
                l10n.update_failed(_errorText(l10n)),
                style: TextStyle(color: p.statusFail, fontSize: 12),
              )
            else if (!_preparing && _asset == null)
              Text(
                l10n.update_noCompatibleAsset,
                style: TextStyle(color: p.textMuted, fontSize: 12),
              )
            else if (_preparing)
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

  String _errorText(AppLocalizations l10n) =>
      _transfer.errorCode == 'expired_url'
          ? l10n.update_expiredUrl
          : (_transfer.message ?? '');

  String _statusText(AppLocalizations l10n) {
    if (_installing) {
      return Platform.isWindows
          ? l10n.update_launchingWindows
          : l10n.update_launchingAndroid;
    }
    return switch (_transfer.stage) {
      UpdateTransferStage.downloading =>
        l10n.update_downloadingProgress((_transfer.progress * 100).round()),
      UpdateTransferStage.retrying =>
        l10n.update_retrying(_transfer.retryAttempt ?? 1),
      UpdateTransferStage.verifying ||
      UpdateTransferStage.assembling =>
        l10n.update_verifying,
      _ => '',
    };
  }

  List<Widget> _actions() {
    final l10n = context.l10n;
    if (_transfer.busy) {
      return [
        TextButton(
          key: const Key('update-cancel'),
          onPressed: _cancel,
          child: Text(l10n.cancel),
        ),
        if (widget.dependencies.coordinator.supportsBackground)
          FilledButton.tonal(
            key: const Key('update-background'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.update_background),
          ),
      ];
    }
    if (_installing) return const [];
    if (_complete) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.done),
        ),
      ];
    }
    if (_transfer.stage == UpdateTransferStage.ready) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.later),
        ),
        FilledButton(
          key: const Key('update-install'),
          onPressed: _installReady,
          child: Text(l10n.update_primary),
        ),
      ];
    }
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.later),
      ),
      if (_transfer.stage == UpdateTransferStage.error ||
          (!_preparing && _asset == null))
        TextButton(
          key: const Key('update-manual'),
          onPressed: _openPage,
          child: Text(l10n.goDownloadPage),
        ),
      if (!_preparing &&
          _transfer.stage == UpdateTransferStage.idle &&
          _asset != null)
        FilledButton(
          key: const Key('update-primary'),
          onPressed: _startUpdate,
          child: Text(l10n.update_primary),
        ),
      if (_transfer.stage == UpdateTransferStage.error && _asset != null)
        FilledButton(
          key: const Key('update-retry'),
          onPressed: _startUpdate,
          child: Text(l10n.retry),
        ),
    ];
  }
}
