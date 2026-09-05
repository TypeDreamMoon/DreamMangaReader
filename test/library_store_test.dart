// 书库存档的**容灾**:一段 JSON 烂了不能连累别的段,更不能让残片把磁盘上
// 还完整的那份覆盖掉 —— 这是「书架和历史一夜之间清空」那类事故的根因。
//
import 'dart:convert';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kFavorites = 'lib.favorites';
const _kHistory = 'lib.history';
const _kWorkProgress = 'lib.workProgress';

String _favoritesJson(List<(String, String)> entries) => jsonEncode([
      for (final (id, title) in entries)
        {'s': 'src', 'm': id, 't': title, 'c': null, 'a': 1},
    ]);

String _historyJson(List<(String, String)> entries) => jsonEncode({
      for (final (id, title) in entries)
        'src:$id': {
          's': 'src',
          'm': id,
          't': title,
          'c': null,
          'lc': 'ch-1',
          'ln': '第 1 话',
          'lp': 3,
          'lt': 20,
          'u': 1000,
          'ch': {
            'ch-1': [3, 20]
          },
        },
    });

Future<LibraryStore> _loaded() async {
  final store = LibraryStore();
  await store.load();
  return store;
}

/// 直接问底层 prefs 磁盘上现在是什么(绕开 store 的内存态)。
Future<String?> _onDisk(String key) async =>
    (await SharedPreferences.getInstance()).getString(key);

Future<List<String>> _keys() async =>
    (await SharedPreferences.getInstance()).getKeys().toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('损坏存档的隔离与保护', () {
    test('收藏损坏不影响历史与偏好', () async {
      SharedPreferences.setMockInitialValues({
        _kFavorites: '{这不是 JSON',
        _kHistory: _historyJson([('m1', '好书')]),
        'lib.preload': 7,
      });

      final store = await _loaded();
      addTearDown(store.dispose);

      expect(store.favoritesLoadFailed, isTrue);
      expect(store.historyLoadFailed, isFalse,
          reason: '收藏那段炸了,历史不该被同一个 try 一起吞掉');
      expect(store.history.single.title, '好书');
      expect(store.preload, 7, reason: '偏好排在收藏之后,也不该被连累');
    });

    test('历史损坏不影响收藏', () async {
      SharedPreferences.setMockInitialValues({
        _kFavorites: _favoritesJson([('m1', '好书')]),
        _kHistory: '[1,2,3]', // 类型错:历史是 Map
      });

      final store = await _loaded();
      addTearDown(store.dispose);

      expect(store.historyLoadFailed, isTrue);
      expect(store.favoritesLoadFailed, isFalse);
      expect(store.favorites.single.title, '好书');
    });

    test('损坏的那段落盘时不会被空表覆盖', () async {
      final intact = _favoritesJson([('m1', '好书'), ('m2', '另一本')]);
      SharedPreferences.setMockInitialValues({
        _kFavorites: '$intact}}坏了',
        _kHistory: _historyJson([('m9', '历史里的书')]),
      });

      final store = await _loaded();
      addTearDown(store.dispose);
      expect(store.favoritesLoadFailed, isTrue);

      // 用户随手收藏一本 → 走 _persistFavorites。磁盘必须原样不动。
      store.toggleFavorite(FavoriteEntry(
        sourceId: 'src',
        mangaId: 'new',
        title: '新收藏',
        addedAt: 2,
      ));
      await store.flushPending();

      expect(await _onDisk(_kFavorites), '$intact}}坏了',
          reason: '内存里只是残片,写回去等于把磁盘上还能修的那份抹掉');
      expect(await _onDisk(_kHistory), isNotNull,
          reason: '没坏的段照常落盘,不受牵连');
    });

    test('历史损坏时防抖落盘与退出落盘都不覆盖磁盘', () async {
      const broken = '{"src:m1": {坏了';
      SharedPreferences.setMockInitialValues({_kHistory: broken});

      final store = await _loaded();
      addTearDown(store.dispose);

      store.markProgress(
        sourceId: 'src',
        mangaId: 'm1',
        title: '好书',
        chapterId: 'ch-1',
        chapterName: '第 1 话',
        page: 1,
        total: 10,
        nowMs: 5,
      );
      await store.flushPending();

      expect(await _onDisk(_kHistory), broken);
    });

    test('损坏原文备份到 <key>.corrupt.<时间戳>', () async {
      const broken = '{"src:m1": 坏了';
      SharedPreferences.setMockInitialValues({_kHistory: broken});

      final store = await _loaded();
      addTearDown(store.dispose);

      final backups =
          (await _keys()).where((k) => k.startsWith('$_kHistory.corrupt.'));
      expect(backups, hasLength(1), reason: '原文要留一份,用户才有得救');
      expect(await _onDisk(backups.first), broken);
    });

    test('恢复备份是明确操作,之后重新允许落盘', () async {
      SharedPreferences.setMockInitialValues({_kFavorites: '坏了'});

      final store = await _loaded();
      addTearDown(store.dispose);
      expect(store.favoritesLoadFailed, isTrue);

      await store.importData({
        'favorites': [
          {'s': 'src', 'm': 'm1', 't': '恢复的书', 'c': null, 'a': 9},
        ],
      });

      expect(store.favoritesLoadFailed, isFalse);
      expect(await _onDisk(_kFavorites), isNot('坏了'));
      expect(store.favorites.single.title, '恢复的书');
    });

    test('作品级共享进度损坏时单独停写,历史照常落盘', () async {
      const broken = '{"好书": 坏了';
      SharedPreferences.setMockInitialValues({_kWorkProgress: broken});

      final store = await _loaded();
      addTearDown(store.dispose);
      expect(store.workProgressLoadFailed, isTrue);
      expect(store.historyLoadFailed, isFalse);

      store.markProgress(
        sourceId: 'src',
        mangaId: 'm1',
        title: '好书',
        chapterId: 'ch-1',
        chapterName: '第 1 话',
        page: 1,
        total: 10,
        nowMs: 5,
      );
      await store.flushPending();

      expect(await _onDisk(_kWorkProgress), broken);
      expect(await _onDisk(_kHistory), contains('m1'));
    });
  });
}
