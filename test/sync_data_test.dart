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

  test('作品共享进度:续读点取时间较新、已读章并集', () {
    final local = blob(1, {
      'workProgress': {
        're0': {'n': 20, 'l': '第20话', 'u': 100, 's': 'a', 'r': [18, 19, 20]}
      }
    });
    final remote = blob(1, {
      'workProgress': {
        're0': {'n': 22, 'l': '第22话', 'u': 200, 's': 'b', 'r': [20, 21, 22]},
        'only': {'n': 3, 'l': '第3话', 'u': 5, 's': 'c', 'r': [3]}
      }
    });
    final wp = (SyncData.merge(local, remote)['library'] as Map)['workProgress']
        as Map;
    // 续读点:remote 更新时间更新(200>100)→ 取 remote。
    expect((wp['re0'] as Map)['n'], 22);
    expect((wp['re0'] as Map)['s'], 'b');
    // 已读章:两端并集 {18,19,20,21,22}。
    expect(((wp['re0'] as Map)['r'] as List).toSet(), {18, 19, 20, 21, 22});
    // 仅一端有的作品保留。
    expect(wp.containsKey('only'), true);
  });

  test('作品共享进度:繁简变体的不同 key 跨设备模糊合并成一份(不留分裂)', () {
    // 设备 A 在简体源读、key=简体核心;设备 B 在繁体源读、key=繁体核心(同长、同作品)。
    final local = blob(1, {
      'workProgress': {
        '我的英雄学院': {'n': 10, 'l': '第10话', 'u': 100, 's': 'a', 'r': [9, 10]}
      }
    });
    final remote = blob(1, {
      'workProgress': {
        '我的英雄學院': {'n': 22, 'l': '第22话', 'u': 200, 's': 'b', 'r': [21, 22]}
      }
    });
    final wp = (SyncData.merge(local, remote)['library'] as Map)['workProgress']
        as Map;
    expect(wp.length, 1); // 两个繁简 key 合成一份,不再分裂
    final only = wp.values.first as Map;
    expect(only['n'], 22); // 续读点取时间新的一方(remote)
    expect((only['r'] as List).toSet(), {9, 10, 21, 22}); // 已读章并集
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

  test('overlay(上传):over 的类别覆盖 base,base 其余保留', () {
    final base = blob(1, {
      'favorites': [fav('x', '1', 1)],
      'gridColumns': 3,
    }, {'repoUrl': 'a'});
    final over = blob(2, {
      'favorites': [fav('y', '2', 2)]
    }); // 只含收藏
    final lib = SyncData.overlay(base, over)['library'] as Map;
    expect((lib['favorites'] as List).length, 1);
    expect((lib['favorites'] as List).first['m'], '2'); // 覆盖为 over 的收藏
    expect(lib['gridColumns'], 3); // base 独有的设置 → 保留
    expect(
        (SyncData.overlay(base, over)['sourceRepo'] as Map)['repoUrl'], 'a');
    // over 无 sourceRepo → 保留 base 的
  });
}
