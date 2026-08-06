import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/features/library/unified_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('projects manga novel and anime history newest first', () {
    final manga = _manga(updatedAt: 10);
    final novel = UnifiedNovelHistoryInput(
      entry: NovelLibraryEntry.remote(
        sourceId: 'novel-source',
        novelId: 'novel-1',
        title: '小说',
      ),
      progress: const NovelReadingProgress(
        locator: NovelLocator(chapterId: 'chapter-1', fraction: .5),
        updatedAt: 20,
      ),
    );
    final anime = _anime(updatedAt: 30);

    final items = UnifiedHistoryProjector.build(
      manga: [manga],
      novel: [novel],
      anime: [anime],
    );

    expect(items.map((item) => item.kind), [
      UnifiedHistoryKind.anime,
      UnifiedHistoryKind.novel,
      UnifiedHistoryKind.manga,
    ]);
    expect(items[0].anime, same(anime));
    expect(items[1].novelEntry, same(novel.entry));
    expect(items[2].manga, same(manga));
  });

  test('equal timestamps use kind then stable key ordering', () {
    final items = UnifiedHistoryProjector.build(
      manga: [_manga(updatedAt: 10, mangaId: 'manga-b')],
      novel: [
        UnifiedNovelHistoryInput(
          entry: NovelLibraryEntry.remote(
            sourceId: 'novel-source',
            novelId: 'novel-a',
            title: '小说',
          ),
          progress: const NovelReadingProgress(
            locator: NovelLocator(chapterId: 'chapter-1'),
            updatedAt: 10,
          ),
        ),
      ],
      anime: [_anime(updatedAt: 10)],
    );

    expect(items.map((item) => item.kind), [
      UnifiedHistoryKind.manga,
      UnifiedHistoryKind.novel,
      UnifiedHistoryKind.anime,
    ]);
    expect(items.map((item) => item.key).toSet(), hasLength(3));
  });

  test('projection keeps existing manga and novel instances unchanged', () {
    final manga = _manga(updatedAt: 1);
    final entry = NovelLibraryEntry.remote(
      sourceId: 's',
      novelId: 'n',
      title: '旧小说历史',
    );
    const progress = NovelReadingProgress(
      locator: NovelLocator(chapterId: 'c'),
      updatedAt: 2,
    );

    final items = UnifiedHistoryProjector.build(
      manga: [manga],
      novel: [UnifiedNovelHistoryInput(entry: entry, progress: progress)],
      anime: const [],
    );

    expect(items.singleWhere((item) => item.manga != null).manga, same(manga));
    expect(
      items.singleWhere((item) => item.novelEntry != null).novelEntry,
      same(entry),
    );
  });
}

ReadState _manga({required int updatedAt, String mangaId = 'manga-1'}) {
  return ReadState(
    sourceId: 'manga-source',
    mangaId: mangaId,
    title: '漫画',
    lastChapterId: 'chapter-1',
    lastChapterName: '第一话',
    lastPage: 2,
    lastTotal: 10,
    updatedAt: updatedAt,
    chapters: {},
  );
}

AnimeHistoryEntry _anime({required int updatedAt}) {
  return AnimeHistoryEntry(
    sourceId: 'anime-source',
    animeId: 'anime-1',
    title: '番剧',
    episodeId: 'episode-1',
    episodeName: '第一集',
    episodeIndex: 0,
    positionSeconds: 12,
    durationSeconds: 100,
    updatedAt: updatedAt,
  );
}
