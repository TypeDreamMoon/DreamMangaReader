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

  test('legacy source repository tokens are stripped while merging', () {
    const sentinel = 'DO_NOT_EXPORT_TOKEN_91f4';
    final legacy = blob(100, {}, {
      'repoUrl': 'https://example.test/sources',
      'localDir': '',
      'token': sentinel,
      'sources.token': sentinel,
      'source.repository.token': sentinel,
    });

    final merged = SyncData.merge(legacy, blob(50, {}));
    final overlaid = SyncData.overlay(legacy, blob(200, {}));

    for (final result in [merged, overlaid]) {
      final encoded = result.toString();
      final sourceRepo = result['sourceRepo'] as Map;
      expect(encoded, isNot(contains(sentinel)));
      expect(sourceRepo.containsKey('token'), isFalse);
      expect(sourceRepo.containsKey('sources.token'), isFalse);
      expect(sourceRepo.containsKey('source.repository.token'), isFalse);
    }
  });

  test('小说源类别支持追加且保留独立序列化键', () {
    expect(SyncData.supportsAppend(SyncCategory.novelSources), true);
    final merged = SyncData.merge(
      blob(100, {
        'disabledSourcesNovel': ['n1'],
        'localSourcesNovel': [
          {'id': 'n1', 'kind': 'novel'}
        ],
      }),
      blob(50, {}),
    );
    final lib = merged['library'] as Map;
    expect(lib['disabledSourcesNovel'], ['n1']);
    expect((lib['localSourcesNovel'] as List).single['kind'], 'novel');
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

  // 并集合并对新增是对的,对删除是灾难:在一台设备上取消收藏,下次同步另一台
  // 又把它并回来,用户永远删不掉。墓碑让「删除」本身也变成一条能同步的记录。
  group('墓碑', () {
    // 测试用的时间戳很小,不给 nowMs 的话墓碑一律「早于 30 天前」被当场清掉。
    Map<String, dynamic> mergeAt(
      Map<String, dynamic> local,
      Map<String, dynamic> remote,
    ) =>
        SyncData.merge(local, remote, nowMs: 1000);

    test('删掉的收藏不会被对端并回来', () {
      final local = blob(200, {
        'favorites': <Map<String, dynamic>>[],
        'favoritesDeleted': {'x:1': 150},
      });
      final remote = blob(100, {
        'favorites': [fav('x', '1', 10)]
      });

      final lib = mergeAt(local, remote)['library'] as Map;
      expect(lib['favorites'], isEmpty);
      expect((lib['favoritesDeleted'] as Map)['x:1'], 150);
    });

    test('删完又加回来的比墓碑新 → 留下', () {
      final local = blob(200, {
        'favorites': [fav('x', '1', 300)], // 300 > 墓碑 150
        'favoritesDeleted': {'x:1': 150},
      });
      final remote = blob(100, {'favorites': <Map<String, dynamic>>[]});

      final favs =
          ((mergeAt(local, remote)['library'] as Map)['favorites'])
              as List;
      expect(favs.single['a'], 300);
    });

    test('墓碑取两端更晚的那次删除', () {
      final local = blob(200, {
        'favorites': [fav('x', '1', 180)],
        'favoritesDeleted': {'x:1': 100},
      });
      final remote = blob(100, {
        'favorites': <Map<String, dynamic>>[],
        'favoritesDeleted': {'x:1': 190}, // 更晚 → 压过 addedAt 180
      });

      final lib = mergeAt(local, remote)['library'] as Map;
      expect(lib['favorites'], isEmpty);
      expect((lib['favoritesDeleted'] as Map)['x:1'], 190);
    });

    test('清掉的历史不会被并回来', () {
      final local = blob(200, {
        'history': <String, dynamic>{},
        'historyDeleted': {'x:2': 150},
      });
      final remote = blob(100, {
        'history': {
          'x:2': {'u': 20},
          'x:3': {'u': 30},
        }
      });

      final history =
          (mergeAt(local, remote)['library'] as Map)['history'] as Map;
      expect(history.containsKey('x:2'), isFalse);
      expect(history.containsKey('x:3'), isTrue, reason: '没被删的照常并过来');
    });

    test('重新启用的源不会被对端并回禁用列表', () {
      final local = blob(200, {
        'disabledSourcesManga': <String>[],
        'disabledSourcesMangaDeleted': {'m1': 150},
      });
      final remote = blob(100, {
        'disabledSourcesManga': ['m1', 'm2']
      });

      final lib = mergeAt(local, remote)['library'] as Map;
      expect(lib['disabledSourcesManga'], ['m2']);
    });

    test('源开关不再整份 LWW:两端各自禁用的都保留', () {
      final local = blob(200, {
        'disabledSourcesManga': ['m1']
      });
      final remote = blob(100, {
        'disabledSourcesManga': ['m2']
      });

      final lib = mergeAt(local, remote)['library'] as Map;
      expect(lib['disabledSourcesManga'], ['m1', 'm2']);
    });

    test('小说收藏 / 历史同样吃墓碑', () {
      final local = {
        'v': 2,
        'syncedAt': 200,
        'library': {'v': 2},
        'novels': {
          'schema': 1,
          'favorites': <Map<String, dynamic>>[],
          'favoritesDeleted': {'n1': 150},
          'history': <String, dynamic>{},
          'historyDeleted': {'n2': 150},
        },
      };
      final remote = {
        'v': 2,
        'syncedAt': 100,
        'library': {'v': 2},
        'novels': {
          'schema': 1,
          'favorites': [
            {'key': 'n1', 'addedAt': 10, 'favorite': true}
          ],
          'history': {
            'n2': {'updatedAt': 10}
          },
        },
      };

      final novels = mergeAt(local, remote)['novels'] as Map;
      expect(novels['favorites'], isEmpty);
      expect(novels['history'], isEmpty);
    });

    test('过了保留期的墓碑被清掉,不无限长大', () {
      final stale = DateTime.now()
          .subtract(SyncData.tombstoneRetention + const Duration(days: 1))
          .millisecondsSinceEpoch;
      final local = blob(200, {
        'favorites': <Map<String, dynamic>>[],
        'favoritesDeleted': {'x:1': stale},
      });
      final remote = blob(100, {'favorites': <Map<String, dynamic>>[]});

      final lib = SyncData.merge(local, remote)['library'] as Map;
      expect(lib.containsKey('favoritesDeleted'), isFalse);
    });

    test('旧 schema(v1、没有墓碑键)照常按并集合并', () {
      final local = blob(200, {
        'favorites': [fav('x', '1', 10)]
      });
      final remote = blob(100, {
        'favorites': [fav('y', '2', 20)]
      });

      final merged = mergeAt(local, remote);
      expect((merged['library'] as Map)['favorites'], hasLength(2));
      expect(merged['v'], SyncData.schemaVersion);
    });

    test('overlay 不会把对端记下的删除盖掉', () {
      final base = blob(1, {
        'favorites': <Map<String, dynamic>>[],
        'favoritesDeleted': {'x:1': 100},
      });
      final over = blob(2, {
        'favorites': [fav('y', '2', 2)],
        'favoritesDeleted': {'y:9': 200},
      });

      final lib = SyncData.overlay(base, over)['library'] as Map;
      expect((lib['favoritesDeleted'] as Map)['x:1'], 100);
      expect((lib['favoritesDeleted'] as Map)['y:9'], 200);
    });

    test('墓碑不会被当成一条设置写回 LibraryStore', () {
      for (final group in SyncTombstoneGroup.values) {
        if (group.section != 'library') continue;
        expect(SyncData.isSettingsKey(group.tombstoneKey), isFalse,
            reason: group.tombstoneKey);
        expect(SyncData.settingsCatOf(group.tombstoneKey), isNull);
      }
    });
  });

  group('墓碑差分', () {
    test('上次在、现在没了 → 记一笔删除', () {
      final marks = SyncData.updateTombstones(
        previous: const {},
        lastKeys: {'a', 'b'},
        currentKeys: {'a'},
        now: 1000,
      );
      expect(marks, {'b': 1000});
    });

    test('又加回来 → 撤销墓碑', () {
      final marks = SyncData.updateTombstones(
        previous: const {'b': 500},
        lastKeys: {'a'},
        currentKeys: {'a', 'b'},
        now: 1000,
      );
      expect(marks, isEmpty);
    });

    test('已有的删除时刻不被后来的差分往后推', () {
      final marks = SyncData.updateTombstones(
        previous: const {'b': 500},
        lastKeys: {'a', 'b'},
        currentKeys: {'a'},
        now: 1000,
      );
      expect(marks, {'b': 500});
    });

    test('liveKeys 只报 blob 真的带了的类别', () {
      final onlyFavorites = blob(1, {
        'favorites': [fav('x', '1', 1)]
      });
      final keys = SyncData.liveKeys(onlyFavorites);
      expect(keys[SyncTombstoneGroup.favorites], {'x:1'});
      // 没带历史 → 不能当成「历史被清空了」。
      expect(keys.containsKey(SyncTombstoneGroup.history), isFalse);
    });
  });
}
