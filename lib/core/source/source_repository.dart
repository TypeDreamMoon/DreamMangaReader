import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'source_registry.dart';

/// 运行时漫画源仓库。
///
/// 引擎**不内置任何源脚本**。启动时按优先级从外部清单(`index.json` + 若干脚本文件)
/// 加载源,填充 [registeredSources]:
///   1. 用户在设置里填的**仓库 URL**(例如某个存放 index.json 的 raw 根地址)——拉取并缓存;
///   2. 用户指定的**本地目录**;
///   3. 上次成功拉取的**磁盘缓存**(离线可用);
///   4. 桌面**开发目录** `./sources_local`(仓库里 .gitignore 掉,方便本地跑);
///   5. 都没有 → **空**(设置里提示去添加源仓库)。
///
/// 清单格式(index.json):
/// ```json
/// {"schema":1,"sources":[
///   {"id":"foo","name":"示例","experimental":true,"useWebView":false,
///    "imageReferer":"https://example/","script":"foo.js"}
/// ]}
/// ```
/// 每个条目的 `script` 是与清单同目录的脚本文件名。
class SourceRepository {
  SourceRepository._();
  static final SourceRepository instance = SourceRepository._();

  static const _kUrl = 'sources.repoUrl';
  static const _kLocal = 'sources.localDir';
  static const _kToken = 'sources.token';

  /// 当前配置(设置页读写)。
  String? repoUrl;
  String? localDir;

  /// 可选的访问令牌:填了就能拉**私有**源仓库(GitHub raw 主机不认 PAT,
  /// 会自动改走 Contents API;其它自建托管则作 Bearer 头)。
  String? token;

  /// 最近一次加载的人类可读状态(设置页展示)。
  String status = '未加载';

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/sources');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 启动时调用(在 runApp 之前)。任何异常都回退到缓存 / 空,绝不让启动崩。
  Future<void> load() async {
    try {
      await _resolve();
    } finally {
      debugPrint('[sources] $status · ${registeredSources.length} 个');
    }
  }

  Future<void> _resolve() async {
    final prefs = await SharedPreferences.getInstance();
    repoUrl = prefs.getString(_kUrl);
    localDir = prefs.getString(_kLocal);
    token = prefs.getString(_kToken);
    try {
      if (repoUrl != null && repoUrl!.trim().isNotEmpty) {
        await _loadFromUrl(repoUrl!.trim());
        return;
      }
      if (localDir != null && localDir!.trim().isNotEmpty) {
        await _loadFromDir(Directory(localDir!.trim()), origin: '本地目录');
        return;
      }
      if (await _loadFromCache()) return;
      // 桌面开发便利:仓库根下 sources_local/(已 gitignore)。
      if (!Platform.isAndroid && !Platform.isIOS) {
        final dev = Directory('sources_local');
        if (await File('${dev.path}/index.json').exists()) {
          await _loadFromDir(dev, origin: '开发目录');
          return;
        }
      }
      registeredSources = [];
      status = '未配置源仓库';
    } catch (e) {
      // 拉取失败:尽量退回缓存,保证离线仍可用。
      if (await _loadFromCache()) {
        status = '加载失败,已用缓存(${registeredSources.length} 个源)';
      } else {
        registeredSources = [];
        status = '加载失败:$e';
      }
    }
  }

  Future<void> _loadFromUrl(String base) async {
    final dio = Dio();
    final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final idxText = await _fetch(dio, '$root/index.json');
    final cache = await _cacheDir();
    await File('${cache.path}/index.json').writeAsString(idxText);
    final metas = <SourceMeta>[];
    for (final e in _entries(idxText)) {
      final scriptFile = e['script'] as String;
      final scriptText = await _fetch(dio, '$root/$scriptFile');
      await File('${cache.path}/$scriptFile').writeAsString(scriptText);
      metas.add(SourceMeta.fromJson(e, script: scriptText));
    }
    registeredSources = metas;
    status = '已从仓库加载 ${metas.length} 个源';
  }

  Future<void> _loadFromDir(Directory dir, {required String origin}) async {
    final idxText = await File('${dir.path}/index.json').readAsString();
    final metas = <SourceMeta>[];
    for (final e in _entries(idxText)) {
      final scriptFile = e['script'] as String;
      final script = await File('${dir.path}/$scriptFile').readAsString();
      metas.add(SourceMeta.fromJson(e, script: script));
    }
    registeredSources = metas;
    status = '已从$origin加载 ${metas.length} 个源';
  }

  Future<bool> _loadFromCache() async {
    final cache = await _cacheDir();
    if (!await File('${cache.path}/index.json').exists()) return false;
    await _loadFromDir(cache, origin: '缓存');
    return registeredSources.isNotEmpty;
  }

  /// 拉一个文件的文本。
  /// - 没配 token:普通 GET(公开 URL / 自建托管)。
  /// - 配了 token 且是 GitHub raw 地址:raw.githubusercontent 不认 PAT,自动改走
  ///   Contents API(`api.github.com/repos/{o}/{r}/contents/{path}?ref={branch}`)+
  ///   `Accept: application/vnd.github.raw` 拿私有仓库原始内容。
  /// - 配了 token 但非 GitHub:作 `Authorization: Bearer <token>`(自建带鉴权托管)。
  Future<String> _fetch(Dio dio, String url) async {
    final t = token?.trim();
    final hasToken = t != null && t.isNotEmpty;
    if (hasToken && url.contains('raw.githubusercontent.com')) {
      final m = RegExp(r'raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)')
          .firstMatch(url);
      if (m != null) {
        final api =
            'https://api.github.com/repos/${m[1]}/${m[2]}/contents/${m[4]}?ref=${m[3]}';
        final r = await dio.get<String>(api,
            options: Options(responseType: ResponseType.plain, headers: {
              'Authorization': 'Bearer $t',
              'Accept': 'application/vnd.github.raw',
              'X-GitHub-Api-Version': '2022-11-28',
            }));
        return r.data!;
      }
    }
    final r = await dio.get<String>(url,
        options: Options(
            responseType: ResponseType.plain,
            headers: hasToken ? {'Authorization': 'Bearer $t'} : null));
    return r.data!;
  }

  List<Map<String, dynamic>> _entries(String jsonText) {
    final m = jsonDecode(jsonText) as Map<String, dynamic>;
    return (m['sources'] as List).cast<Map<String, dynamic>>();
  }

  /// 设置里改仓库 URL 后调用:持久化并重新加载。
  Future<void> setRepoUrl(String? url) async {
    final prefs = await SharedPreferences.getInstance();
    final v = url?.trim();
    if (v == null || v.isEmpty) {
      await prefs.remove(_kUrl);
    } else {
      await prefs.setString(_kUrl, v);
      await prefs.remove(_kLocal); // URL 优先,清掉本地目录避免歧义
    }
    await load();
  }

  /// 持久化访问令牌(拉私有源仓库用)。只落盘不重载——重载由随后的 setRepoUrl 触发,
  /// 避免用新 token + 旧 URL 多拉一次。
  Future<void> setToken(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    final v = value?.trim();
    token = (v == null || v.isEmpty) ? null : v;
    if (token == null) {
      await prefs.remove(_kToken);
    } else {
      await prefs.setString(_kToken, token!);
    }
  }

  /// 设置里选本地目录后调用:持久化并重新加载。
  Future<void> setLocalDir(String? dir) async {
    final prefs = await SharedPreferences.getInstance();
    final v = dir?.trim();
    if (v == null || v.isEmpty) {
      await prefs.remove(_kLocal);
    } else {
      await prefs.setString(_kLocal, v);
      await prefs.remove(_kUrl);
    }
    await load();
  }
}
