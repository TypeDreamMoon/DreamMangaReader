import 'dart:convert';

import 'package:dream_manga_reader/app/anime_library_store.dart';
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
