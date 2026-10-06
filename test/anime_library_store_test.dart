import 'dart:convert';

import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  test('anime favorites toggle and reload from their own namespace', () async {
    final store = AnimeLibraryStore(persistDelay: Duration.zero);
    await store.load();

    store.toggleFavorite(const AnimeFavoriteEntry(
      sourceId: 'anime-source',
      animeId: 'show-1',
      title: '测试番剧',
      cover: 'https://example.test/cover.jpg',
      addedAt: 20,
    ));
    await store.flushPending();

    final restored = AnimeLibraryStore(persistDelay: Duration.zero);
    await restored.load();
    expect(restored.isFavorite('anime-source', 'show-1'), isTrue);
    expect(restored.favorites.single.title, '测试番剧');

    restored.toggleFavorite(restored.favorites.single);
    await restored.flushPending();
    expect(restored.favorites, isEmpty);
    store.dispose();
    restored.dispose();
  });

  test('anime history persists one record per integer second', () async {
    final store = AnimeLibraryStore(persistDelay: Duration.zero);
    await store.load();

    store.saveProgress(
      sourceId: 's',
      animeId: 'a',
      title: '番剧',
      episodeId: 'ep-2',
      episodeName: '第二集',
      episodeIndex: 1,
      position: const Duration(milliseconds: 12600),
      duration: const Duration(minutes: 24),
      updatedAt: 30,
    );
    store.saveProgress(
      sourceId: 's',
      animeId: 'a',
      title: '番剧',
      episodeId: 'ep-2',
      episodeName: '第二集',
      episodeIndex: 1,
      position: const Duration(milliseconds: 12900),
      duration: const Duration(minutes: 24),
      updatedAt: 31,
    );
    await store.flushPending();

    expect(store.history.single.positionSeconds, 12);
    expect(store.history.single.durationSeconds, 1440);
    expect(store.history.single.updatedAt, 30);
    store.dispose();
  });

  // 每秒一次全量序列化 + 一次 setString,是这层最容易回潮的性能坑。
  test('a playing episode persists on a throttle, not once a second', () async {
    final store = AnimeLibraryStore(
      persistDelay: const Duration(milliseconds: 600),
      progressPersistDelay: const Duration(seconds: 5),
    );
    await store.load();
    addTearDown(store.dispose);
    // 第一次是「开始看这一集」,属于结构变化,不走节流。
    _saveAt(store, 1);
    await store.flushPending();
    var notifications = 0;
    store.addListener(() => notifications++);
    final baseline = store.persistCount;

    fakeAsync((async) {
      for (var second = 2; second <= 31; second++) {
        _saveAt(store, second);
        async.elapse(const Duration(seconds: 1));
      }
    });

    // 30 秒的播放:节流住是 6 次,没节流就是 30 次。
    expect(store.persistCount - baseline, 6);
    // 位置往前走不该把挂在 scope 上的整棵树重建一遍。
    expect(notifications, 0);
  });

  test('a flush publishes the progress the throttle held back', () async {
    final store = AnimeLibraryStore(
      persistDelay: Duration.zero,
      progressPersistDelay: const Duration(seconds: 5),
    );
    await store.load();
    addTearDown(store.dispose);
    _saveAt(store, 1);
    await store.flushPending();
    var notifications = 0;
    store.addListener(() => notifications++);

    _saveAt(store, 2);
    expect(notifications, 0);

    // 暂停 / 切集 / 退出 / 进后台都会走到这里,「继续观看」在那一刻才刷新。
    await store.flushPending();
    expect(notifications, 1);
    expect(store.history.single.positionSeconds, 2);
  });

  test('history sorts newest first and supports targeted and full removal',
      () async {
    final store = AnimeLibraryStore(persistDelay: Duration.zero);
    await store.load();
    _save(store, animeId: 'old', updatedAt: 10);
    _save(store, animeId: 'new', updatedAt: 30);
    _save(store, animeId: 'middle', updatedAt: 20);

    expect(store.history.map((entry) => entry.animeId), [
      'new',
      'middle',
      'old',
    ]);
    store.removeHistory('s', 'middle');
    expect(store.history.map((entry) => entry.animeId), ['new', 'old']);
    store.clearHistory();
    expect(store.history, isEmpty);
    store.dispose();
  });

  test('load skips malformed anime records and repairs persisted data',
      () async {
    SharedPreferences.setMockInitialValues({
      'anime.library.v1': jsonEncode([
        {
          'sourceId': 's',
          'animeId': 'valid',
          'title': '有效番剧',
          'addedAt': 1,
        },
        {'sourceId': 's'},
        'broken',
      ]),
      'anime.history.v1': jsonEncode([
        {
          'sourceId': 's',
          'animeId': 'valid',
          'title': '有效番剧',
          'episodeId': 'ep-1',
          'episodeName': '第一集',
          'episodeIndex': 0,
          'positionSeconds': 8,
          'durationSeconds': 100,
          'updatedAt': 2,
        },
        {'animeId': 'broken'},
      ]),
    });
    final store = AnimeLibraryStore(persistDelay: Duration.zero);

    await store.load();
    await store.flushPending();

    expect(store.favorites.single.animeId, 'valid');
    expect(store.history.single.positionSeconds, 8);
    final prefs = await SharedPreferences.getInstance();
    expect(
        jsonDecode(prefs.getString('anime.library.v1')!) as List, hasLength(1));
    expect(
        jsonDecode(prefs.getString('anime.history.v1')!) as List, hasLength(1));
    store.dispose();
  });

  test('export and import preserve anime data without transport secrets',
      () async {
    final store = AnimeLibraryStore(persistDelay: Duration.zero);
    await store.load();
    store.toggleFavorite(const AnimeFavoriteEntry(
      sourceId: 's',
      animeId: 'a',
      title: '番剧',
      addedAt: 1,
    ));
    _save(store, animeId: 'a', updatedAt: 2);

    final data = store.exportData();
    expect(jsonEncode(data), isNot(contains('token')));
    expect(jsonEncode(data), isNot(contains('cookie')));

    final restored = AnimeLibraryStore(persistDelay: Duration.zero);
    await restored.load();
    restored.importData(data);
    expect(restored.favorites.single.animeId, 'a');
    expect(restored.history.single.episodeId, 'ep-1');
    store.dispose();
    restored.dispose();
  });
}

/// 同一部、同一集,只有位置往前走了 [second] 秒。
void _saveAt(AnimeLibraryStore store, int second) {
  store.saveProgress(
    sourceId: 's',
    animeId: 'a',
    title: '番剧',
    episodeId: 'ep-1',
    episodeName: '第一集',
    episodeIndex: 0,
    position: Duration(seconds: second),
    duration: const Duration(minutes: 24),
    updatedAt: second,
  );
}

void _save(
  AnimeLibraryStore store, {
  required String animeId,
  required int updatedAt,
}) {
  store.saveProgress(
    sourceId: 's',
    animeId: animeId,
    title: animeId,
    episodeId: 'ep-1',
    episodeName: '第一集',
    episodeIndex: 0,
    position: const Duration(seconds: 8),
    duration: const Duration(seconds: 100),
    updatedAt: updatedAt,
  );
}
