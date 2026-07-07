import '../../app/library_store.dart';
import '../source/source_repository.dart';

/// 云同步的数据 blob:书架数据(收藏/历史/设置/源开关,复用 [LibraryStore.exportData])
/// + 源仓库配置(repoUrl/localDir/token)。**不含**每源登录 token(安全起见,新设备重新登录)
/// 与下载文件/缓存(太大)。
///
/// 合并策略(双向同步不丢数据):
///   - 收藏:两端并集(同一 sourceId:mangaId 取 addedAt 较新的)。
///   - 历史/进度:逐条按 updatedAt 取较新。
///   - 其余标量设置 / 源开关 / 源仓配置:取整份 `syncedAt` 较新的一方(last-writer-wins)。
class SyncData {
  static int _int(Object? v) => (v is num) ? v.toInt() : 0;
  static Map<String, dynamic> _map(Object? v) =>
      (v is Map) ? v.cast<String, dynamic>() : <String, dynamic>{};
  static List _list(Object? v) => (v is List) ? v : const [];

  /// 从本地各 store 组装当前 blob。
  static Map<String, dynamic> build(LibraryStore lib, SourceRepository repo) => {
        'v': 1,
        'syncedAt': DateTime.now().millisecondsSinceEpoch,
        'library': lib.exportData(),
        'sourceRepo': {
          'repoUrl': repo.repoUrl ?? '',
          'localDir': repo.localDir ?? '',
          'token': repo.token ?? '',
        },
      };

  /// 合并两个 blob(本地 + 远端),返回带全新 syncedAt 的合并结果。
  static Map<String, dynamic> merge(
      Map<String, dynamic> local, Map<String, dynamic> remote) {
    final newer = _int(remote['syncedAt']) >= _int(local['syncedAt']) ? remote : local;
    final lLib = _map(local['library']);
    final rLib = _map(remote['library']);
    // 以「较新」整份 library 打底(拿到较新的设置/源开关),再把收藏/历史无损合并盖上。
    final lib = Map<String, dynamic>.from(_map(newer['library']));
    lib['favorites'] = _mergeFavorites(_list(lLib['favorites']), _list(rLib['favorites']));
    lib['history'] = _mergeHistory(_map(lLib['history']), _map(rLib['history']));
    return {
      'v': 1,
      'syncedAt': DateTime.now().millisecondsSinceEpoch,
      'library': lib,
      'sourceRepo': newer['sourceRepo'] ?? local['sourceRepo'] ?? remote['sourceRepo'],
    };
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

  /// 把合并后的 blob 应用到本地:书架数据走 importData;源仓配置走 SourceRepository(会触发重载)。
  static Future<void> apply(
      Map<String, dynamic> blob, LibraryStore lib, SourceRepository repo) async {
    final library = _map(blob['library']);
    if (library.isNotEmpty) await lib.importData(library);
    // 源仓配置:失败不连累整体同步(网络/私有仓等)。
    try {
      final sr = _map(blob['sourceRepo']);
      final url = (sr['repoUrl'] as String?)?.trim() ?? '';
      final dir = (sr['localDir'] as String?)?.trim() ?? '';
      final tok = (sr['token'] as String?)?.trim() ?? '';
      // 仅在与当前不同时才动(避免每次同步都重拉源)。
      if (tok != (repo.token ?? '')) await repo.setToken(tok.isEmpty ? null : tok);
      if (url.isNotEmpty && url != (repo.repoUrl ?? '')) {
        await repo.setRepoUrl(url);
      } else if (url.isEmpty && dir.isNotEmpty && dir != (repo.localDir ?? '')) {
        await repo.setLocalDir(dir);
      }
    } catch (_) {}
  }
}
