import '../../app/anime_library_store.dart';
import '../../app/library_store.dart';
import '../../app/novel_library_store.dart';

enum UnifiedHistoryKind { manga, novel, anime }

class UnifiedNovelHistoryInput {
  const UnifiedNovelHistoryInput({
    required this.entry,
    required this.progress,
  });

  final NovelLibraryEntry entry;
  final NovelReadingProgress progress;
}

class UnifiedHistoryItem {
  const UnifiedHistoryItem._({
    required this.kind,
    required this.key,
    required this.title,
    required this.cover,
    required this.updatedAt,
    this.manga,
    this.novelEntry,
    this.novelProgress,
    this.anime,
  });

  factory UnifiedHistoryItem.manga(ReadState state) => UnifiedHistoryItem._(
        kind: UnifiedHistoryKind.manga,
        key: 'manga:${state.key}',
        title: state.title,
        cover: state.cover,
        updatedAt: state.updatedAt,
        manga: state,
      );

  factory UnifiedHistoryItem.novel(UnifiedNovelHistoryInput input) =>
      UnifiedHistoryItem._(
        kind: UnifiedHistoryKind.novel,
        key: 'novel:${input.entry.key}',
        title: input.entry.title,
        cover: input.entry.cover,
        updatedAt: input.progress.updatedAt,
        novelEntry: input.entry,
        novelProgress: input.progress,
      );

  factory UnifiedHistoryItem.anime(AnimeHistoryEntry entry) =>
      UnifiedHistoryItem._(
        kind: UnifiedHistoryKind.anime,
        key: 'anime:${entry.key}',
        title: entry.title,
        cover: entry.cover,
        updatedAt: entry.updatedAt,
        anime: entry,
      );

  final UnifiedHistoryKind kind;
  final String key;
  final String title;
  final String? cover;
  final int updatedAt;
  final ReadState? manga;
  final NovelLibraryEntry? novelEntry;
  final NovelReadingProgress? novelProgress;
  final AnimeHistoryEntry? anime;
}

abstract final class UnifiedHistoryProjector {
  static List<UnifiedHistoryItem> build({
    required Iterable<ReadState> manga,
    required Iterable<UnifiedNovelHistoryInput> novel,
    required Iterable<AnimeHistoryEntry> anime,
  }) {
    final items = <UnifiedHistoryItem>[
      for (final state in manga) UnifiedHistoryItem.manga(state),
      for (final input in novel) UnifiedHistoryItem.novel(input),
      for (final entry in anime) UnifiedHistoryItem.anime(entry),
    ];
    items.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      if (byTime != 0) return byTime;
      final byKind = a.kind.index.compareTo(b.kind.index);
      if (byKind != 0) return byKind;
      return a.key.compareTo(b.key);
    });
    return List.unmodifiable(items);
  }
}
