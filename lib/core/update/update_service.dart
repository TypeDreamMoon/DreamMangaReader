import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_info.dart';
import '../../app/theme/app_colors.dart';
import 'update_installer.dart';

/// 一个可更新的版本。
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.url,
    required this.notes,
    required this.prerelease,
    this.assets = const [],
  });

  final String tag; // v1.2.0
  final String version; // 1.2.0
  final String url; // release 页面
  final String notes; // 更新说明(release body)
  final bool prerelease; // 是否测试版
  final List<UpdateAsset> assets; // release 附件(APK / setup.exe),应用内更新用
}

/// 检查 GitHub Releases 有没有比当前更新的版本。
class UpdateService {
  UpdateService._();

  static const _owner = 'TypeDreamMoon';
  static const _repo = 'DreamMangaReader';

  static final Dio _dio = Dio(BaseOptions(
    headers: {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'DreamMangaReader-UpdateCheck',
    },
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 12),
    validateStatus: (_) => true,
  ));

  /// 查最新版本。[includeBeta]=true 时把预发布(-beta/-rc/-alpha)也算进来。
  /// **当前若本身是预发布,自动包含预发布**——beta 用户就该收到 beta 更新。
  /// 返回严格比当前版本高(含 -beta.N 逐级比较)的最高版本;已是最新 / 失败返回 null。
  static Future<UpdateInfo?> check({bool includeBeta = false}) async {
    try {
      final r = await _dio.get<dynamic>(
        'https://api.github.com/repos/$_owner/$_repo/releases',
        queryParameters: {'per_page': 20},
      );
      if (r.statusCode != 200 || r.data is! List) return null;
      final list = (r.data as List).whereType<Map>().cast<Map<String, dynamic>>();

      final wantBeta = includeBeta || isPrerelease(AppInfo.version);

      // 遍历所有 release,挑「非草稿、允许的类型、版本号严格更高」里**版本最高**的
      // (release 列表通常按时间倒序,但版本号未必单调,故按版本号取最大)。
      UpdateInfo? best;
      for (final rel in list) {
        if (rel['draft'] == true) continue;
        final pre = rel['prerelease'] == true;
        if (pre && !wantBeta) continue;
        final tag = (rel['tag_name'] ?? '').toString();
        if (compareVersions(tag, AppInfo.version) <= 0) continue; // 不比当前新
        if (best != null && compareVersions(tag, best.tag) <= 0) continue;
        final assets = <UpdateAsset>[
          for (final a in (rel['assets'] as List? ?? const []))
            if (a is Map &&
                a['name'] != null &&
                a['browser_download_url'] != null)
              UpdateAsset(
                  a['name'].toString(), a['browser_download_url'].toString()),
        ];
        best = UpdateInfo(
          tag: tag,
          version: tag.replaceFirst(RegExp(r'^v'), ''),
          url: (rel['html_url'] ??
                  'https://github.com/$_owner/$_repo/releases')
              .toString(),
          notes: (rel['body'] ?? '').toString().trim(),
          prerelease: pre,
          assets: assets,
        );
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  /// 当前 tag/版本是否为预发布(带 -beta/-rc/-alpha 后缀)。
  static bool isPrerelease(String s) =>
      RegExp(r'-(?:beta|rc|alpha)', caseSensitive: false).hasMatch(s);

  /// 语义化版本比较:先比 major.minor.patch;base 相等时正式版 > 预发布,预发布之间
  /// 按标识符逐段比(beta.3 < beta.4、beta.9 < beta.10、alpha < beta)。a>b 正、a<b 负、相等 0。
  static int compareVersions(String a, String b) {
    final (baseA, preA) = _semver(a);
    final (baseB, preB) = _semver(b);
    for (var i = 0; i < 3; i++) {
      if (baseA[i] != baseB[i]) return baseA[i] - baseB[i];
    }
    if (preA.isEmpty && preB.isEmpty) return 0;
    if (preA.isEmpty) return 1; // 正式版 > 预发布
    if (preB.isEmpty) return -1;
    final n = preA.length < preB.length ? preA.length : preB.length;
    for (var i = 0; i < n; i++) {
      final x = preA[i], y = preB[i];
      final xn = int.tryParse(x), yn = int.tryParse(y);
      if (xn != null && yn != null) {
        if (xn != yn) return xn - yn; // 数字段按数值
      } else if (xn != null) {
        return -1; // 数字标识符 < 字母标识符
      } else if (yn != null) {
        return 1;
      } else {
        final c = x.compareTo(y);
        if (c != 0) return c;
      }
    }
    return preA.length - preB.length; // 前缀相同时,少标识符者更小
  }

  /// "v1.2.0-beta.3+5" → ([1,2,0], ['beta','3'])。忽略 build 元数据(+…)。
  static (List<int>, List<String>) _semver(String s) {
    var t = s.trim().replaceFirst(RegExp(r'^v'), '');
    final plus = t.indexOf('+');
    if (plus >= 0) t = t.substring(0, plus);
    final dash = t.indexOf('-');
    final basePart = dash >= 0 ? t.substring(0, dash) : t;
    final preRaw = dash >= 0 ? t.substring(dash + 1) : '';
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(basePart);
    final base = m == null
        ? const [0, 0, 0]
        : [
            int.parse(m.group(1)!),
            int.parse(m.group(2)!),
            int.parse(m.group(3)!)
          ];
    final pre = preRaw.isEmpty ? const <String>[] : preRaw.split('.');
    return (base, pre);
  }
}

/// 弹出「发现新版本」对话框:版本 + 更新说明 + **应用内一键更新**(下载进度),
/// 不支持自更新的平台 / 缺少对应附件时退回浏览器下载页。
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _UpdateDialog(info: info),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});
  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double _progress = 0; // 0~1;-1 = 总量未知
  bool _busy = false; // 正在下载/安装
  bool _launched = false; // Android:安装器已打开
  String? _error;

  UpdateAsset? get _asset => UpdateInstaller.pickAsset(widget.info.assets);
  bool get _canInApp => UpdateInstaller.supported && _asset != null;

  Future<void> _startUpdate() async {
    final asset = _asset;
    if (asset == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
    });
    try {
      await UpdateInstaller.downloadAndInstall(asset,
          onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      // Android:到这 = 安装器已打开;Windows:静默安装前进程已退出,一般到不了这里。
      if (mounted) {
        setState(() {
          _launched = true;
          _busy = false;
        });
      }
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
    launchUrl(Uri.parse(widget.info.url), mode: LaunchMode.externalApplication);
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
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: Text(
                  widget.info.notes.isEmpty ? '暂无更新说明。' : widget.info.notes,
                  style: TextStyle(
                      color: p.textMuted, fontSize: 12.5, height: 1.5),
                ),
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
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(), // 后台继续下载
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
