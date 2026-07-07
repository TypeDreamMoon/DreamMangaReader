import '../../app/library_store.dart';
import '../source/source_repository.dart';

/// 可选择同步的内容类别。用户可在设置里勾选只同步其中几项。
enum SyncCategory {
  favorites, // 收藏
  history, // 阅读进度 / 历史
  settings, // 阅读/界面设置(除收藏/历史/源开关外的所有标量)
  sources, // 源开关(disabledSources)
  sourceRepo, // 源仓库配置(repoUrl/localDir/token)
}

/// 云同步的数据 blob:书架数据(收藏/历史/设置/源开关,复用 [LibraryStore.exportData])
/// + 源仓库配置。**不含**每源登录 token(安全,新设备重登)与下载文件(太大)。
///
/// 【选择性同步】[build] 只放入所选类别;[merge] 取两端出现过的类别的并集(所以另一台设备
/// 才同步的类别不会被抹掉,留在服务端);[apply] 只把**本机所选**类别写回本地。
///
/// 合并策略(双向不丢数据):
///   - 收藏:两端并集(同 sourceId:mangaId 取 addedAt 较新)。
///   - 历史/进度:逐条按 updatedAt 取较新。
///   - 设置 / 源开关 / 源仓配置:整份按 `syncedAt` 较新一方(last-writer-wins),仅一方有则取那方。
class SyncData {
  static int _int(Object? v) => (v is num) ? v.toInt() : 0;
  static Map<String, dynamic> _map(Object? v) =>
      (v is Map) ? v.cast<String, dynamic>() : <String, dynamic>{};
  static List _list(Object? v) => (v is List) ? v : const [];

  /// library 里属于「设置」类别的键(排除收藏/历史/源开关与版本标记)。
  static bool _isSettingsKey(String k) =>
      k != 'v' && k != 'favorites' && k != 'history' && k != 'disabledSources';

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
    if (categories.contains(SyncCategory.sources)) {
      outLib['disabledSources'] = full['disabledSources'];
    }
    if (categories.contains(SyncCategory.settings)) {
      for (final e in full.entries) {
        if (_isSettingsKey(e.key)) outLib[e.key] = e.value;
      }
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

  /// 合并两个 blob(本地 + 远端)。**按类别取并集**:两端都有的类别按规则合并,只有一方
  /// 有的类别原样保留(这样另一台设备才同步的类别不会在本机这轮被抹掉)。返回全新 syncedAt。
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
        // 设置标量 / disabledSources:整份 LWW,仅一方有则取那方。
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

  /// last-writer-wins,带「在场」判断:仅一方有该键则取那方,两方都有取 syncedAt 较新者。
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

  /// 把合并后的 blob 应用到本地——**只应用 [categories] 所选类别**(没选的本地数据不动)。
  static Future<void> apply(
    Map<String, dynamic> blob,
    LibraryStore lib,
    SourceRepository repo, {
    required Set<SyncCategory> categories,
  }) async {
    final blib = _map(blob['library']);
    final toImport = <String, dynamic>{'v': 1};

    final importFav = categories.contains(SyncCategory.favorites) &&
        blib.containsKey('favorites');
    final importHist = categories.contains(SyncCategory.history) &&
        blib.containsKey('history');
    if (importFav) toImport['favorites'] = blib['favorites'];
    if (importHist) toImport['history'] = blib['history'];
    if (categories.contains(SyncCategory.sources) &&
        blib.containsKey('disabledSources')) {
      toImport['disabledSources'] = blib['disabledSources'];
    }
    if (categories.contains(SyncCategory.settings)) {
      for (final e in blib.entries) {
        if (_isSettingsKey(e.key)) toImport[e.key] = e.value;
      }
    }
    // 只在导入对应类别时才覆盖收藏/历史,否则本地保持不动。设置/源开关走「缺省即保留」。
    await lib.importData(toImport,
        replaceFavorites: importFav, replaceHistory: importHist);

    if (categories.contains(SyncCategory.sourceRepo)) {
      // 源仓配置:失败不连累整体同步(网络/私有仓等)。
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
}
