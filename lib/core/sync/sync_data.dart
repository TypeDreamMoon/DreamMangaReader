import '../../app/library_store.dart';
import '../source/source_registry.dart' show registeredSources;
import '../source/source_repository.dart';

/// 可选择同步的内容类别。源开关按内容类型拆成漫画源 / 番剧源两档。
enum SyncCategory {
  favorites, // 收藏
  history, // 阅读进度 / 历史
  settings, // 阅读/界面设置(整份,不再细拆)
  mangaSources, // 漫画源开关(disabledSources 中 kind=manga 的)
  animeSources, // 番剧源开关(disabledSources 中 kind=anime 的)
  sourceRepo, // 源仓库配置(repoUrl/localDir/token)
}

/// 云同步的数据 blob:书架数据(收藏/历史/设置/源开关)+ 源仓库配置。
/// **不含**每源登录 token 与下载文件。
///
/// - [build] 只放所选类别;源开关按 source kind 拆成 `disabledSourcesManga/Anime`。
/// - [merge] 类别并集(自动双向同步用)。
/// - [overlay] 把 over 的类别盖到 base 上(上传:本地覆盖服务器对应类别,保留其余)。
/// - [apply] 把 blob 的所选类别写回本地;`append=false` 覆盖,`append=true` 追加
///   (收藏/历史并集、源开关并集,设置/源仓保持本地不动)。
class SyncData {
  static int _int(Object? v) => (v is num) ? v.toInt() : 0;
  static Map<String, dynamic> _map(Object? v) =>
      (v is Map) ? v.cast<String, dynamic>() : <String, dynamic>{};
  static List _list(Object? v) => (v is List) ? v : const [];
  static List<String> _strList(Object? v) =>
      (v is List) ? v.map((e) => e.toString()).toList() : <String>[];

  /// library 里属于「设置」类别的键(排除收藏/历史/源开关与版本标记)。
  static bool _isSettingsKey(String k) =>
      k != 'v' && k != 'favorites' && k != 'history' && k != 'disabledSources';

  /// 源 id 是否为番剧源。未知(源已移除/未加载)按漫画处理。
  static bool _isAnimeId(String id) {
    for (final m in registeredSources) {
      if (m.id == id) return m.isAnime;
    }
    return false;
  }

  /// 导出当前已加载的某类源的完整定义(含脚本正文 'code'),让源本身也能被同步。
  static List<Map<String, dynamic>> _exportSources(bool anime) => [
        for (final m in registeredSources)
          if (m.isAnime == anime)
            {
              'id': m.id,
              'name': m.name,
              'kind': m.kind,
              'experimental': m.experimental,
              'useWebView': m.useWebView,
              'imageReferer': m.imageReferer,
              'needsLogin': m.needsLogin,
              'code': m.script,
            },
      ];

  static List<Map<String, dynamic>> _entryList(Object? v) => (v is List)
      ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : const <Map<String, dynamic>>[];

  /// 从本地各 store 组装当前 blob——只包含 [categories] 所选类别。
  static Map<String, dynamic> build(
    LibraryStore lib,
    SourceRepository repo, {
    required Set<SyncCategory> categories,
  }) {
    final full = lib.exportData();
    final outLib = <String, dynamic>{'v': 1};
    if (categories.contains(SyncCategory.favorites)) {
      outLib['favorites'] = full['favorites'];
    }
    if (categories.contains(SyncCategory.history)) {
      outLib['history'] = full['history'];
    }
    if (categories.contains(SyncCategory.settings)) {
      for (final e in full.entries) {
        if (_isSettingsKey(e.key)) outLib[e.key] = e.value;
      }
    }
    final allDisabled = _strList(full['disabledSources']);
    if (categories.contains(SyncCategory.mangaSources)) {
      outLib['disabledSourcesManga'] =
          allDisabled.where((id) => !_isAnimeId(id)).toList();
      outLib['localSourcesManga'] = _exportSources(false); // 源脚本本身
    }
    if (categories.contains(SyncCategory.animeSources)) {
      outLib['disabledSourcesAnime'] = allDisabled.where(_isAnimeId).toList();
      outLib['localSourcesAnime'] = _exportSources(true);
    }
    final blob = <String, dynamic>{
      'v': 1,
      'syncedAt': DateTime.now().millisecondsSinceEpoch,
      'library': outLib,
    };
    if (categories.contains(SyncCategory.sourceRepo)) {
      blob['sourceRepo'] = {
        'repoUrl': repo.repoUrl ?? '',
        'localDir': repo.localDir ?? '',
        'token': repo.token ?? '',
      };
    }
    return blob;
  }

  /// 合并两个 blob——**按类别取并集**(只有一方有的类别原样保留)。自动双向同步用。
  static Map<String, dynamic> merge(
      Map<String, dynamic> local, Map<String, dynamic> remote) {
    final lTs = _int(local['syncedAt']);
    final rTs = _int(remote['syncedAt']);
    final lLib = _map(local['library']);
    final rLib = _map(remote['library']);

    final outLib = <String, dynamic>{'v': 1};
    final keys = {...lLib.keys, ...rLib.keys}..remove('v');
    for (final k in keys) {
      if (k == 'favorites') {
        outLib[k] = _mergeFavorites(_list(lLib[k]), _list(rLib[k]));
      } else if (k == 'history') {
        outLib[k] = _mergeHistory(_map(lLib[k]), _map(rLib[k]));
      } else {
        outLib[k] = _lww(
            lLib.containsKey(k), lLib[k], lTs, rLib.containsKey(k), rLib[k], rTs);
      }
    }

    final out = <String, dynamic>{
      'v': 1,
      'syncedAt': DateTime.now().millisecondsSinceEpoch,
      'library': outLib,
    };
    final sr = _lww(local.containsKey('sourceRepo'), local['sourceRepo'], lTs,
        remote.containsKey('sourceRepo'), remote['sourceRepo'], rTs);
    if (sr != null) out['sourceRepo'] = sr;
    return out;
  }

  /// 把 [over] 出现的类别覆盖到 [base] 上,base 其余类别原样保留(上传语义:
  /// 本地覆盖服务器对应类别,不动服务器上别的类别)。
  static Map<String, dynamic> overlay(
      Map<String, dynamic> base, Map<String, dynamic> over) {
    final outLib = Map<String, dynamic>.from(_map(base['library']))..['v'] = 1;
    _map(over['library']).forEach((k, v) {
      if (k != 'v') outLib[k] = v;
    });
    final out = <String, dynamic>{
      'v': 1,
      'syncedAt': DateTime.now().millisecondsSinceEpoch,
      'library': outLib,
    };
    final sr = over.containsKey('sourceRepo')
        ? over['sourceRepo']
        : base['sourceRepo'];
    if (sr != null) out['sourceRepo'] = sr;
    return out;
  }

  static dynamic _lww(
      bool hasL, dynamic lv, int lTs, bool hasR, dynamic rv, int rTs) {
    if (!hasL) return rv;
    if (!hasR) return lv;
    return rTs >= lTs ? rv : lv;
  }

  static List _mergeFavorites(List a, List b) {
    final by = <String, Map>{};
    void add(List xs) {
      for (final x in xs) {
        if (x is! Map) continue;
        final key = '${x['s']}:${x['m']}';
        final prev = by[key];
        if (prev == null || _int(x['a']) >= _int(prev['a'])) by[key] = x;
      }
    }

    add(a);
    add(b);
    return by.values.toList();
  }

  static Map<String, dynamic> _mergeHistory(Map a, Map b) {
    final out = <String, dynamic>{};
    void add(Map xs) {
      xs.forEach((k, v) {
        if (v is! Map) return;
        final prev = out[k];
        if (prev == null || _int(v['u']) >= _int((prev as Map)['u'])) {
          out[k.toString()] = v;
        }
      });
    }

    add(a);
    add(b);
    return out;
  }

  /// 把 [blob] 写回本地——[modes] 逐类别指定方式:
  ///   不在 map 里 = 不下载该类;`false` = 覆盖(用服务器替换本地);`true` = 追加。
  /// 追加:收藏/历史/源开关取并集;设置/源仓库无「追加」语义,只有覆盖(false)才应用。
  static Future<void> apply(
    Map<String, dynamic> blob,
    LibraryStore lib,
    SourceRepository repo, {
    required Map<SyncCategory, bool> modes,
  }) async {
    final blib = _map(blob['library']);
    final mangaMode = modes[SyncCategory.mangaSources];
    final animeMode = modes[SyncCategory.animeSources];

    // 源脚本:先导入(importLocalSources 会 reload 刷新 registeredSources),后面 toggle 的
    // kind 判断才准。覆盖(false)= 替换该类本地源;追加(true)= 合并保留。
    if (mangaMode != null && blib['localSourcesManga'] is List) {
      await repo.importLocalSources(_entryList(blib['localSourcesManga']),
          restrictKind: 'manga', replace: mangaMode == false);
    }
    if (animeMode != null && blib['localSourcesAnime'] is List) {
      await repo.importLocalSources(_entryList(blib['localSourcesAnime']),
          restrictKind: 'anime', replace: animeMode == false);
    }

    final full = lib.exportData(); // 当前本地态:供追加合并 + 源开关重建
    final toImport = <String, dynamic>{'v': 1};

    final favMode = modes[SyncCategory.favorites];
    final histMode = modes[SyncCategory.history];
    final importFav = favMode != null && blib.containsKey('favorites');
    final importHist = histMode != null && blib.containsKey('history');
    if (importFav) {
      toImport['favorites'] = favMode == true
          ? _mergeFavorites(_list(full['favorites']), _list(blib['favorites']))
          : blib['favorites'];
    }
    if (importHist) {
      toImport['history'] = histMode == true
          ? _mergeHistory(_map(full['history']), _map(blib['history']))
          : blib['history'];
    }
    // 设置:只有覆盖(false)才应用;追加/不选保持本地。
    if (modes[SyncCategory.settings] == false) {
      for (final e in blib.entries) {
        if (_isSettingsKey(e.key)) toImport[e.key] = e.value;
      }
    }
    // 源开关:按 kind 分别重建整份 disabledSources 交给 importData。
    final wantManga =
        mangaMode != null && blib.containsKey('disabledSourcesManga');
    final wantAnime =
        animeMode != null && blib.containsKey('disabledSourcesAnime');
    if (wantManga || wantAnime) {
      final result = Set<String>.from(_strList(full['disabledSources']));
      if (wantManga) {
        if (mangaMode == false) result.removeWhere((id) => !_isAnimeId(id));
        result.addAll(_strList(blib['disabledSourcesManga']));
      }
      if (wantAnime) {
        if (animeMode == false) result.removeWhere(_isAnimeId);
        result.addAll(_strList(blib['disabledSourcesAnime']));
      }
      toImport['disabledSources'] = result.toList();
    }

    await lib.importData(toImport,
        replaceFavorites: importFav, replaceHistory: importHist);

    // 源仓库:只有覆盖(false)才应用。失败不连累整体。
    if (modes[SyncCategory.sourceRepo] == false) {
      try {
        final sr = _map(blob['sourceRepo']);
        final url = (sr['repoUrl'] as String?)?.trim() ?? '';
        final dir = (sr['localDir'] as String?)?.trim() ?? '';
        final tok = (sr['token'] as String?)?.trim() ?? '';
        if (tok != (repo.token ?? '')) {
          await repo.setToken(tok.isEmpty ? null : tok);
        }
        if (url.isNotEmpty && url != (repo.repoUrl ?? '')) {
          await repo.setRepoUrl(url);
        } else if (url.isEmpty && dir.isNotEmpty && dir != (repo.localDir ?? '')) {
          await repo.setLocalDir(dir);
        }
      } catch (_) {}
    }
  }

  /// 哪些类别支持「追加」(其余只有覆盖):收藏/历史/源开关是集合可并;设置/源仓库是整份值。
  static bool supportsAppend(SyncCategory c) =>
      c == SyncCategory.favorites ||
      c == SyncCategory.history ||
      c == SyncCategory.mangaSources ||
      c == SyncCategory.animeSources;
}
