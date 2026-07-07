import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../net/image_cache.dart' show dirSizeBytes;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../script/script_source.dart' show ScriptSource;
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

  /// 当前 registeredSources 里哪些是「本地单文件源」(用户手动加的),供 UI 标注/移除。
  Set<String> localIds = {};

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/sources');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 源缓存(清单 + 脚本)占用的磁盘字节数。
  Future<int> cacheSizeBytes() async {
    try {
      return await dirSizeBytes(await _cacheDir());
    } catch (_) {
      return 0;
    }
  }

  /// 清掉源缓存(下次启动/刷新会重新拉取)。内存里已加载的源不受影响。
  Future<void> clearCache() async {
    try {
      final d = await _cacheDir();
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
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

    // 1) 仓库源(URL / 本地目录 / 缓存 / 开发目录)。
    var repo = <SourceMeta>[];
    var repoStatus = '未配置源仓库';
    try {
      if (repoUrl != null && repoUrl!.trim().isNotEmpty) {
        repo = await _loadFromUrl(repoUrl!.trim());
        repoStatus = '已从仓库加载 ${repo.length} 个源';
      } else if (localDir != null && localDir!.trim().isNotEmpty) {
        repo = await _loadFromDir(Directory(localDir!.trim()));
        repoStatus = '已从本地目录加载 ${repo.length} 个源';
      } else {
        final cached = await _loadFromCache();
        if (cached != null) {
          repo = cached;
          repoStatus = '已从缓存加载 ${repo.length} 个源';
        } else if (!Platform.isAndroid && !Platform.isIOS) {
          // 桌面开发便利:仓库根下 sources_local/(已 gitignore)。
          final dev = Directory('sources_local');
          if (await File('${dev.path}/index.json').exists()) {
            repo = await _loadFromDir(dev);
            repoStatus = '已从开发目录加载 ${repo.length} 个源';
          }
        }
      }
    } catch (e) {
      // 拉取失败:尽量退回缓存,保证离线仍可用。
      final cached = await _loadFromCache();
      if (cached != null) {
        repo = cached;
        repoStatus = '加载失败,已用缓存(${repo.length} 个源)';
      } else {
        repoStatus = '加载失败:$e';
      }
    }

    // 2) 本地单文件源(用户手动加的),合并进来;id 与仓库源冲突则以仓库源为准。
    final local = await _loadLocalSources();
    final repoIds = repo.map((e) => e.id).toSet();
    final localKept = local.where((e) => !repoIds.contains(e.id)).toList();

    registeredSources = [...repo, ...localKept];
    localIds = localKept.map((e) => e.id).toSet();
    status =
        localKept.isEmpty ? repoStatus : '$repoStatus · +${localKept.length} 本地源';
  }

  Future<List<SourceMeta>> _loadFromUrl(String base) async {
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
    return metas;
  }

  Future<List<SourceMeta>> _loadFromDir(Directory dir) async {
    final idxText = await File('${dir.path}/index.json').readAsString();
    final metas = <SourceMeta>[];
    for (final e in _entries(idxText)) {
      final scriptFile = e['script'] as String;
      final script = await File('${dir.path}/$scriptFile').readAsString();
      metas.add(SourceMeta.fromJson(e, script: script));
    }
    return metas;
  }

  Future<List<SourceMeta>?> _loadFromCache() async {
    final cache = await _cacheDir();
    if (!await File('${cache.path}/index.json').exists()) return null;
    final list = await _loadFromDir(cache);
    return list.isEmpty ? null : list;
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

  // ---- 本地单文件源(用户手动加的单个 .js,不需要整套仓库/清单) ----

  Future<Directory> _localSourcesDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/local_sources');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<SourceMeta>> _loadLocalSources() async {
    try {
      final dir = await _localSourcesDir();
      final idx = File('${dir.path}/index.json');
      if (!await idx.exists()) return [];
      final metas = <SourceMeta>[];
      for (final e in _entries(await idx.readAsString())) {
        final f = File('${dir.path}/${e['script']}');
        if (!await f.exists()) continue;
        metas.add(SourceMeta.fromJson(e, script: await f.readAsString()));
      }
      return metas;
    } catch (_) {
      return [];
    }
  }

  /// 加一个本地单文件源(.js)。从脚本 `__source.meta` 读 id/name(脚本还可在 meta 里
  /// 声明 useWebView / imageReferer / needsLogin);拷进本地源目录并登记,随后重载。
  /// 返回源展示名;脚本语法错误或缺 id 会抛异常。
  Future<String> addLocalSource(String jsPath) async {
    final text = await File(jsPath).readAsString();
    final meta = ScriptSource.readMeta(text); // eval 脚本,顺便验证语法/结构
    final id = (meta['id'] as String?)?.trim();
    if (id == null || id.isEmpty) {
      throw Exception('脚本的 __source.meta 缺少 id');
    }
    final entry = <String, dynamic>{
      'id': id,
      'name': (meta['name'] as String?) ?? id,
      'experimental': (meta['experimental'] as bool?) ?? true,
      'useWebView': (meta['useWebView'] as bool?) ?? false,
      'imageReferer': meta['imageReferer'],
      'needsLogin': (meta['needsLogin'] as bool?) ?? false,
      'script': '$id.js',
    };
    final dir = await _localSourcesDir();
    await File('${dir.path}/$id.js').writeAsString(text);
    final idxFile = File('${dir.path}/index.json');
    final list = await idxFile.exists()
        ? _entries(await idxFile.readAsString())
        : <Map<String, dynamic>>[];
    list.removeWhere((e) => e['id'] == id); // 同 id 覆盖
    list.add(entry);
    await idxFile.writeAsString(jsonEncode({'schema': 1, 'sources': list}));
    await load();
    return entry['name'] as String;
  }

  /// 移除一个本地单文件源。
  Future<void> removeLocalSource(String id) async {
    try {
      final dir = await _localSourcesDir();
      final idxFile = File('${dir.path}/index.json');
      if (await idxFile.exists()) {
        final list = _entries(await idxFile.readAsString())
          ..removeWhere((e) => e['id'] == id);
        await idxFile.writeAsString(jsonEncode({'schema': 1, 'sources': list}));
      }
      final js = File('${dir.path}/$id.js');
      if (await js.exists()) await js.delete();
    } catch (_) {}
    await load();
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
