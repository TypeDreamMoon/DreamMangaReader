import 'package:flutter_test/flutter_test.dart';
import 'package:dream_manga_reader/core/sync/sync_data.dart';

/// 覆盖 SyncData.merge 的纯逻辑(选择性同步的核心:按类别取并集 + 各类别合并规则)。
void main() {
  Map<String, dynamic> blob(int ts, Map<String, dynamic> lib,
          [Map<String, dynamic>? sr]) =>
      {
        'v': 1,
        'syncedAt': ts,
        'library': {'v': 1, ...lib},
        if (sr != null) 'sourceRepo': sr,
      };
  Map<String, dynamic> fav(String s, String m, int a) =>
      {'s': s, 'm': m, 't': '$s$m', 'a': a};

  test('按类别取并集:仅远端有的类别得以保留', () {
    final local = blob(100, {
      'favorites': [fav('x', '1', 10)]
    });
    final remote = blob(50, {
      'history': {'x:2': {'u': 5}},
      'readerMode': 'webtoon',
    });
    final lib = SyncData.merge(local, remote)['library'] as Map;
    expect((lib['favorites'] as List).length, 1);
    expect((lib['history'] as Map).containsKey('x:2'), true); // 远端独有 → 保留
    expect(lib['readerMode'], 'webtoon'); // 远端独有的设置 → 保留
  });

  test('收藏并集:同一本取 addedAt 较新', () {
    final local = blob(1, {
      'favorites': [fav('x', '1', 10), fav('x', '2', 5)]
    });
    final remote = blob(1, {
      'favorites': [fav('x', '1', 20)]
    });
    final favs = (SyncData.merge(local, remote)['library'] as Map)['favorites']
        as List;
    expect(favs.length, 2);
    expect(favs.firstWhere((e) => e['m'] == '1')['a'], 20);
  });

  test('历史:逐条取 updatedAt 较新', () {
    final local = blob(1, {
      'history': {
        'k': {'u': 10}
      }
    });
    final remote = blob(1, {
      'history': {
        'k': {'u': 30}
      }
    });
    final h = (SyncData.merge(local, remote)['library'] as Map)['history'] as Map;
    expect(h['k']['u'], 30);
  });

  test('设置标量:整份按 syncedAt LWW', () {
    expect(
      (SyncData.merge(blob(200, {'gridColumns': 3}), blob(100, {'gridColumns': 5}))[
              'library'] as Map)['gridColumns'],
      3, // 本地较新
    );
    expect(
      (SyncData.merge(blob(100, {'gridColumns': 3}), blob(200, {'gridColumns': 5}))[
              'library'] as Map)['gridColumns'],
      5, // 远端较新
    );
  });

  test('sourceRepo:仅一方有则保留', () {
    final m = SyncData.merge(blob(1, {}, {'repoUrl': 'a'}), blob(1, {}));
    expect((m['sourceRepo'] as Map)['repoUrl'], 'a');
  });
}
