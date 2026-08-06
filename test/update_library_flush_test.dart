import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('update exit flushes manga novel and anime libraries', () async {
    SharedPreferences.setMockInitialValues(const {});
    final manga = LibraryStore();
    final novel = NovelLibraryStore();
    final anime = AnimeLibraryStore(persistDelay: const Duration(hours: 1));
    await manga.load();
    await novel.load();
    await anime.load();

    manga.toggleFavorite(FavoriteEntry(
      sourceId: 'manga-source',
      mangaId: 'manga-1',
      title: '漫画',
      addedAt: 1,
    ));
    novel.toggleRemoteFavorite(NovelLibraryEntry.remote(
      sourceId: 'novel-source',
      novelId: 'novel-1',
      title: '小说',
    ));
    anime.toggleFavorite(const AnimeFavoriteEntry(
      sourceId: 'anime-source',
      animeId: 'anime-1',
      title: '番剧',
      addedAt: 1,
    ));

    await flushLibraryStoresBeforeExit(manga, novel, anime);

    final restoredManga = LibraryStore();
    final restoredNovel = NovelLibraryStore();
    final restoredAnime = AnimeLibraryStore();
    await restoredManga.load();
    await restoredNovel.load();
    await restoredAnime.load();
    expect(restoredManga.favorites, hasLength(1));
    expect(
        restoredNovel.entries.where((entry) => entry.favorite), hasLength(1));
    expect(restoredAnime.favorites, hasLength(1));

    manga.dispose();
    novel.dispose();
    anime.dispose();
    restoredManga.dispose();
    restoredNovel.dispose();
    restoredAnime.dispose();
  });
}
