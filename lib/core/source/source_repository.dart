import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../net/image_cache.dart' show dirSizeBytes;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../log/app_log.dart';
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
  static const _kRemoved = 'sources.removed'; // 用户删掉的仓库源 id(持久隐藏,可恢复)

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

  /// 被用户「删除」的仓库源 id:重载后仍过滤掉(本地源是真删文件,不进这里)。可整体恢复。
  Set<String> removedIds = {};

  /// 源/仓库配置变化钩子(云同步「变化后自动上传」挂这里;app 启动时接线)。
  /// 所有修改路径(加/删源、导入、改仓库配置)最后都会 [load] 重载,故挂在 load 末尾
  /// 即可全覆盖;[setToken] 不重载,单独补一次。
  void Function()? onChanged;

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
      final n = registeredSources.length;
      final lvl = status.contains('失败')
          ? LogLevel.error
          : (n == 0 ? LogLevel.warning : LogLevel.success);
      AppLog.i.log(LogCat.source, '加载源 · $n 个 · $status', level: lvl);
      onChanged?.call();
    }
  }

  Future<void> _resolve() async {
    final prefs = await SharedPreferences.getInstance();
    repoUrl = prefs.getString(_kUrl);
    localDir = prefs.getString(_kLocal);
    token = prefs.getString(_kToken);
    removedIds = (prefs.getStringList(_kRemoved) ?? const <String>[]).toSet();

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

    // 3) 内置原生源(B站番剧)。不来自仓库/脚本,启动即注入(除非用户手动隐藏)。
    //    仓库若也定义了同 id,以内置为准(去重),把内置排在最前。
    final combined = [
      kBiliSourceMeta,
      ...repo.where((e) => e.id != kBiliSourceId),
      ...localKept.where((e) => e.id != kBiliSourceId),
    ];
    registeredSources =
        combined.where((e) => !removedIds.contains(e.id)).toList();
    localIds =
        localKept.where((e) => !removedIds.contains(e.id)).map((e) => e.id).toSet();
    final hidden = removedIds.isEmpty ? '' : ' · 隐藏 ${removedIds.length}';
    status = (localKept.isEmpty
            ? repoStatus
            : '$repoStatus · +${localKept.length} 本地源') +
        hidden;
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

  /// 从一个 **zip** 导入源(zip 里含 `index.json` + 若干 `.js` 脚本,即一整套源仓库打包)。
  /// 解压 → 逐条把脚本落进本地源目录(统一命名 `{id}.js` 避免与仓库源重名)、合并进本地清单 → 重载。
  /// 同 id 覆盖;脚本 eval 失败 / index 里缺脚本的源自动跳过。返回成功导入的源数量。
  Future<int> addLocalSourceZip(String zipPath) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    Map<String, dynamic>? index;
    final scripts = <String, List<int>>{}; // basename → 内容
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final base = f.name.split(RegExp(r'[/\\]')).last;
      if (base.isEmpty) continue;
      final data = f.content as List<int>;
      if (base == 'index.json') {
        index = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      } else if (base.toLowerCase().endsWith('.js')) {
        scripts[base] = data;
      }
    }
    if (index == null) throw Exception('zip 里没有 index.json');
    final entries =
        (index['sources'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

    final dir = await _localSourcesDir();
    final idxFile = File('${dir.path}/index.json');
    final list = await idxFile.exists()
        ? _entries(await idxFile.readAsString())
        : <Map<String, dynamic>>[];

    var added = 0;
    for (final e in entries) {
      final id = (e['id'] as String?)?.trim();
      final scriptName = (e['script'] as String?)?.split(RegExp(r'[/\\]')).last;
      if (id == null || id.isEmpty || scriptName == null) continue;
      final data = scripts[scriptName];
      if (data == null) continue; // 该源的脚本不在 zip 里
      final text = utf8.decode(data);
      try {
        ScriptSource.readMeta(text); // 验证脚本能 eval,坏的跳过
      } catch (_) {
        continue;
      }
      await File('${dir.path}/$id.js').writeAsString(text);
      final entry = Map<String, dynamic>.from(e)..['script'] = '$id.js';
      list.removeWhere((x) => x['id'] == id); // 同 id 覆盖
      list.add(entry);
      added++;
    }
    if (added == 0) {
      throw Exception('zip 里没有可用的源(index.json 与脚本对不上?)');
    }
    await idxFile.writeAsString(jsonEncode({'schema': 1, 'sources': list}));
    await load();
    return added;
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

  /// 删除一个源:本地单文件源 → 真删磁盘文件;仓库源 → 记入隐藏集(重载后仍不显示,可整体恢复)。
  Future<void> deleteSource(String id) async {
    if (localIds.contains(id)) {
      await removeLocalSource(id); // 内部会 load()
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    removedIds.add(id);
    await prefs.setStringList(_kRemoved, removedIds.toList());
    await load();
  }

  /// 恢复所有被删除(隐藏)的仓库源。
  Future<void> restoreRemoved() async {
    final prefs = await SharedPreferences.getInstance();
    removedIds.clear();
    await prefs.remove(_kRemoved);
    await load();
  }

  /// 从云同步导入源脚本(每条 [entries] 含 `code`=脚本正文)。写进本地源目录、合并清单、重载,
  /// 使它们在本机成为「本地源」。[restrictKind] 只处理该 kind;[replace]=true 先删掉(该 kind 的)
  /// 现有本地源(覆盖语义)。返回导入数量。
  Future<int> importLocalSources(List<Map<String, dynamic>> entries,
      {String? restrictKind, bool replace = false}) async {
    final dir = await _localSourcesDir();
    final idxFile = File('${dir.path}/index.json');
    var list = await idxFile.exists()
        ? _entries(await idxFile.readAsString())
        : <Map<String, dynamic>>[];
    bool sameKind(Map<String, dynamic> e) =>
        restrictKind == null ||
        ((e['kind'] as String?) ?? 'manga') == restrictKind;
    if (replace) {
      for (final e in list.where(sameKind)) {
        try {
          final js = File('${dir.path}/${e['script']}');
          if (await js.exists()) await js.delete();
        } catch (_) {}
      }
      list = list.where((e) => !sameKind(e)).toList();
    }
    var n = 0;
    for (final e in entries) {
      final id = (e['id'] as String?)?.trim();
      final code = e['code'] as String?;
      if (id == null || id.isEmpty || code == null) continue;
      if (restrictKind != null &&
          ((e['kind'] as String?) ?? 'manga') != restrictKind) {
        continue;
      }
      await File('${dir.path}/$id.js').writeAsString(code);
      list.removeWhere((x) => x['id'] == id); // 同 id 覆盖
      list.add(<String, dynamic>{
        'id': id,
        'name': e['name'] ?? id,
        'kind': e['kind'] ?? 'manga',
        'experimental': e['experimental'] ?? true,
        'useWebView': e['useWebView'] ?? false,
        'imageReferer': e['imageReferer'],
        'needsLogin': e['needsLogin'] ?? false,
        'script': '$id.js',
      });
      n++;
    }
    await idxFile.writeAsString(jsonEncode({'schema': 1, 'sources': list}));
    await load();
    return n;
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
    onChanged?.call();
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
