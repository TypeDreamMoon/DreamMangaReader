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

  /// 查最新版本。[includeBeta]=true 时把预发布(-beta/-rc)也算进来。
  /// 返回比当前**主版本号**新的 [UpdateInfo];已是最新 / 查询失败返回 null。
  static Future<UpdateInfo?> check({bool includeBeta = false}) async {
    try {
      final r = await _dio.get<dynamic>(
        'https://api.github.com/repos/$_owner/$_repo/releases',
        queryParameters: {'per_page': 15},
      );
      if (r.statusCode != 200 || r.data is! List) return null;
      final list = (r.data as List).whereType<Map>().cast<Map<String, dynamic>>();

      // releases 按发布时间倒序;取第一个「非草稿、且(允许测试版或非测试版)」的。
      Map<String, dynamic>? best;
      for (final rel in list) {
        if (rel['draft'] == true) continue;
        if (rel['prerelease'] == true && !includeBeta) continue;
        best = rel;
        break;
      }
      if (best == null) return null;

      final tag = (best['tag_name'] ?? '').toString();
      if (_compare(_parse(tag), _parse(AppInfo.version)) <= 0) {
        return null; // 不比当前新
      }
      return UpdateInfo(
        tag: tag,
        version: tag.replaceFirst(RegExp(r'^v'), ''),
        url: (best['html_url'] ??
                'https://github.com/$_owner/$_repo/releases')
            .toString(),
        notes: (best['body'] ?? '').toString().trim(),
        prerelease: best['prerelease'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  // "v1.2.0-beta.1" / "1.2.0" → [1,2,0](忽略预发布后缀比主版本)。
  static List<int> _parse(String s) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(s);
    if (m == null) return const [0, 0, 0];
    return [
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    ];
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
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
