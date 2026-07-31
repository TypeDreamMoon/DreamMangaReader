import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_info.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../ui/ui.dart';
import '../log/app_log.dart';
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

/// 弹出「发现新版本」对话框:版本 + 更新说明 + **应用内一键更新**(下载进度),
/// 不支持自更新的平台 / 缺少对应附件时退回浏览器下载页。
Future<void> showUpdateDialog(BuildContext context, UpdateCandidate info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false, // 下载/安装中别被点外面误关(尤其 Windows 会自杀重启)
    builder: (ctx) => _UpdateDialog(info: info),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});
  final UpdateCandidate info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double _progress = 0; // 0~1;-1 = 总量未知
  bool _busy = false; // 正在下载/安装
  bool _launched = false; // Android:安装器已打开
  String? _error;
  CancelToken? _cancel; // 下载取消令牌

  RemoteAsset? get _asset => UpdateInstaller.pickAsset(widget.info.assets);
  bool get _canInApp => UpdateInstaller.supported && _asset != null;

  Future<void> _startUpdate() async {
    final asset = _asset;
    if (asset == null) return;
    final store = LibraryScope.read(context); // Windows exit(0) 前用它落盘
    final cancel = _cancel = CancelToken();
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
    });
    try {
      await UpdateInstaller.downloadAndInstall(
        asset,
        cancelToken: cancel,
        onBeforeExit: () => store.flushPending(),
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      // Android:到这 = 安装器已打开;Windows:静默安装前进程已退出,一般到不了这里。
      if (mounted) {
        setState(() {
          _launched = true;
          _busy = false;
        });
      }
    } on DioException catch (e) {
      // 用户主动取消:不当错误,复位即可。
      if (e.type != DioExceptionType.cancel && mounted) {
        setState(() => _error = '$e');
      }
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  void _openPage() {
    launchUrl(Uri.parse(widget.info.pageUrl),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      backgroundColor: p.surface,
      title: Text(
        '发现新版本 ${widget.info.tag}${widget.info.prerelease ? ' · 测试版' : ''}',
        style: TextStyle(
            color: p.textPrimary, fontSize: 16, fontWeight: FontWeight.w800),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: widget.info.notes.isEmpty
                    ? Text('暂无更新说明。',
                        style: TextStyle(
                            color: p.textMuted, fontSize: 12.5, height: 1.5))
                    // Release Note 是 Markdown,渲染成带样式的富文本。
                    : MarkdownView(widget.info.notes),
              ),
            ),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _progress >= 0 ? _progress : null,
              backgroundColor: p.line,
            ),
            const SizedBox(height: 8),
            Text(
              _progress >= 1.0
                  ? (Theme.of(context).platform == TargetPlatform.windows
                      ? '下载完成 · 正在安装并重启…'
                      : '下载完成 · 正在打开安装器…')
                  : _progress >= 0
                      ? '下载中 ${(_progress * 100).round()}%'
                      : '下载中…',
              style: TextStyle(color: p.textMuted, fontSize: 12),
            ),
          ],
          if (_launched) ...[
            const SizedBox(height: 12),
            Text('安装器已打开,按提示完成安装即可',
                style: TextStyle(color: p.textPrimary, fontSize: 12.5)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text('更新失败:$_error',
                style: TextStyle(color: p.statusFail, fontSize: 12)),
          ],
        ],
      ),
      actions: _actions(),
    );
  }

  List<Widget> _actions() {
    if (_busy) {
      // Windows 装好会自杀重启,没法「后台边用边更」→ 给「取消」(停下载、留在原版);
      // Android 装完只是弹系统安装器、不动本进程 → 可「后台」继续下载。
      return [
        Platform.isWindows
            ? TextButton(
                onPressed: () => _cancel?.cancel('user'),
                child: const Text('取消'),
              )
            : TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('后台'),
              ),
      ];
    }
    if (_launched) {
      return [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成')),
      ];
    }
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('稍后'),
      ),
      if (_error != null || !_canInApp)
        TextButton(onPressed: _openPage, child: const Text('去下载页')),
      if (_canInApp)
        FilledButton(
          onPressed: _startUpdate,
          child: Text(_error != null ? '重试' : '一键更新'),
        ),
    ];
  }
}
