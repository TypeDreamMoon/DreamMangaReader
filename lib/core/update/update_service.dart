import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_info.dart';
import '../../app/theme/app_colors.dart';

/// 一个可更新的版本。
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.url,
    required this.notes,
    required this.prerelease,
  });

  final String tag; // v1.2.0
  final String version; // 1.2.0
  final String url; // release 页面
  final String notes; // 更新说明(release body)
  final bool prerelease; // 是否测试版
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
        best = UpdateInfo(
          tag: tag,
          version: tag.replaceFirst(RegExp(r'^v'), ''),
          url: (rel['html_url'] ??
                  'https://github.com/$_owner/$_repo/releases')
              .toString(),
          notes: (rel['body'] ?? '').toString().trim(),
          prerelease: pre,
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

/// 弹出「发现新版本」对话框:显示版本 + 更新说明,可去 Release 页下载。
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  final p = context.palette;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.surface,
      title: Text(
        '发现新版本 ${info.tag}${info.prerelease ? ' · 测试版' : ''}',
        style: TextStyle(
            color: p.textPrimary, fontSize: 16, fontWeight: FontWeight.w800),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(
          child: Text(
            info.notes.isEmpty ? '暂无更新说明。' : info.notes,
            style: TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.5),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            launchUrl(Uri.parse(info.url),
                mode: LaunchMode.externalApplication);
          },
          child: const Text('去下载'),
        ),
      ],
    ),
  );
}
