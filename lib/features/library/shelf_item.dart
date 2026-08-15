import '../../app/anime_library_store.dart';
import '../../app/library_store.dart';
import '../../app/novel_library_store.dart';
import '../../core/library/update_checker.dart';
import '../../core/source/title_match.dart';

/// 书架上的内容类型。书架不再是「漫画 + 两条附属横条」,三类同级,
/// 靠这个枚举做筛选与卡片角标(null = 全部)。
enum ShelfKind { manga, novel, anime }

/// 书架收藏的统一投影:漫画 / 小说 / 番剧三类收藏归一成同一种卡片数据,
/// 于是一个 [FeedView] 就能把它们混排,布局(瀑布流/网格/列表)也只写一份。
///
/// 与 [UnifiedHistoryItem](历史那条线)是对称的:那个统一「在读」,这个统一「收藏」。
class ShelfItem {
  const ShelfItem._({
    required this.kind,
    required this.key,
    required this.title,
    required this.cover,
    required this.addedAt,
    this.subtitle = '',
    this.sourceCount = 1,
    this.available = true,
    this.mangaEntry,
    this.novelEntry,
    this.animeEntry,
  });

  /// [sources] = 该作品跨源去重后覆盖的源数(驱动封面「N源」角标)。
  factory ShelfItem.manga(FavoriteEntry entry, {int sources = 1}) =>
      ShelfItem._(
        kind: ShelfKind.manga,
        key: 'manga:${entry.key}',
        title: entry.title,
        cover: entry.cover,
        addedAt: entry.addedAt,
        sourceCount: sources,
        mangaEntry: entry,
      );

  factory ShelfItem.novel(NovelLibraryEntry entry) => ShelfItem._(
        kind: ShelfKind.novel,
        key: 'novel:${entry.key}',
        title: entry.title,
        cover: entry.cover,
        addedAt: entry.addedAt,
        subtitle: entry.authors.join(' / '),
        available: entry.available,
        novelEntry: entry,
      );

  factory ShelfItem.anime(AnimeFavoriteEntry entry) => ShelfItem._(
        kind: ShelfKind.anime,
        key: 'anime:${entry.key}',
        title: entry.title,
        cover: entry.cover,
        addedAt: entry.addedAt,
        animeEntry: entry,
      );

  final ShelfKind kind;

  /// 全局唯一(带 kind 前缀):Hero tag / ValueKey 用,三类混排也不会撞。
  final String key;
  final String title;
  final String? cover;
  final int addedAt; // epoch ms,倒序排列用

  /// 副标题(小说的作者;其余为空)。
  final String subtitle;

  /// >1 时封面显示「N源」角标(仅漫画会跨源去重)。
  final int sourceCount;

  /// false = 本地文件已丢失(小说),卡片不可点。
  final bool available;

  final FavoriteEntry? mangaEntry;
  final NovelLibraryEntry? novelEntry;
  final AnimeFavoriteEntry? animeEntry;

  /// 搜索匹配:标题或作者命中(小写包含)。
  bool matches(String lowerQuery) =>
      title.toLowerCase().contains(lowerQuery) ||
      subtitle.toLowerCase().contains(lowerQuery);
}

abstract final class ShelfProjector {
  /// 三类收藏合并成一条按**收藏时间倒序**的列表。
  /// [kind] 非空则只出该类;[query] 非空则按标题/作者过滤。
  static List<ShelfItem> build({
    required LibraryStore manga,
    required NovelLibraryStore novel,
    required AnimeLibraryStore anime,
    ShelfKind? kind,
    String query = '',
  }) {
    final items = <ShelfItem>[
      if (kind == null || kind == ShelfKind.manga)
        for (final group in dedupMangaFavorites(manga))
          ShelfItem.manga(group.rep, sources: group.sources),
      if (kind == null || kind == ShelfKind.novel)
        for (final entry in novel.entries)
          if (entry.favorite) ShelfItem.novel(entry),
      if (kind == null || kind == ShelfKind.anime)
        for (final entry in anime.favorites) ShelfItem.anime(entry),
    ];
    final q = query.trim().toLowerCase();
    final filtered =
        q.isEmpty ? items : [for (final i in items) if (i.matches(q)) i];
    filtered.sort((a, b) {
      final byTime = b.addedAt.compareTo(a.addedAt);
      if (byTime != 0) return byTime;
      final byKind = a.kind.index.compareTo(b.kind.index);
      return byKind != 0 ? byKind : a.key.compareTo(b.key);
    });
    return List.unmodifiable(filtered);
  }

  /// 追更要检查的收藏。口径与书架卡片一致(漫画已跨源去重,查的就是卡片代表的
  /// 那个源),所以角标贴回卡片时一定对得上。
  ///
  /// 本地导入的小说没有源、更新无从谈起,直接排除 —— 否则它们会永远停在
  /// 「检查失败」那一栏里。
  static List<UpdateTarget> updateTargets({
    required LibraryStore manga,
    required NovelLibraryStore novel,
    required AnimeLibraryStore anime,
  }) {
    final out = <UpdateTarget>[];
    for (final item in build(manga: manga, novel: novel, anime: anime)) {
      final (String, String)? ref = switch (item.kind) {
        ShelfKind.manga => (item.mangaEntry!.sourceId, item.mangaEntry!.mangaId),
        ShelfKind.anime => (item.animeEntry!.sourceId, item.animeEntry!.animeId),
        // 本地导入的小说没有 sourceId,跳过。
        ShelfKind.novel => switch (item.novelEntry!) {
            final e when e.sourceId != null && e.novelId != null =>
              (e.sourceId!, e.novelId!),
            _ => null,
          },
      };
      if (ref == null) continue;
      out.add(UpdateTarget(
        shelfKey: item.key,
        sourceId: ref.$1,
        itemId: ref.$2,
        title: item.title,
      ));
    }
    return List.unmodifiable(out);
  }

  /// 收藏去重:同一部书的多源副本合成一组,代表优先「最后阅读的源」的那条
  /// (没有则最近收藏的)。返回顺序 = [LibraryStore.favorites] 的顺序(最近在前)。
  static List<({FavoriteEntry rep, int sources})> dedupMangaFavorites(
      LibraryStore store) {
    final srcMap = _sourcesByWork(store); // 权威分组 key
    final groups = <String, List<FavoriteEntry>>{}; // 插入序 = 收藏序(最近在前)
    for (final f in store.favorites) {
      final core = coreTitle(f.title);
      final key = core.isEmpty ? 'raw:${f.key}' : _canonKey(core, srcMap.keys);
      (groups[key] ??= []).add(f);
    }
    final out = <({FavoriteEntry rep, int sources})>[];
    groups.forEach((key, group) {
      final lastSrc = store.workProgressFor(group.first.title)?.lastSourceId;
      var rep = group.first;
      if (lastSrc != null) {
        for (final f in group) {
          if (f.sourceId == lastSrc) {
            rep = f;
            break;
          }
        }
      }
      out.add((rep: rep, sources: srcMap[key]?.length ?? 1));
    });
    return out;
  }

  /// 同一作品(容繁简/装饰副标题,与书架去重同口径)的全部收藏与历史条目。
  /// 标题归一化为空(纯符号名)时书架也是按单条出卡的,组操作只作用于被点的
  /// 那一条([sourceId]:[mangaId]),不能按字面标题误伤其它同符号名的书。
  static ({List<FavoriteEntry> favs, List<ReadState> hist}) workEntries(
    LibraryStore store,
    String title, {
    required String sourceId,
    required String mangaId,
  }) {
    final core = coreTitle(title);
    if (core.isEmpty) {
      return (
        favs: [
          for (final f in store.favorites)
            if (f.sourceId == sourceId && f.mangaId == mangaId) f
        ],
        hist: [
          for (final h in store.history)
            if (h.sourceId == sourceId && h.mangaId == mangaId) h
        ],
      );
    }
    bool same(String t) {
      final c = coreTitle(t);
      return c == core || sameCoreKey(c, core);
    }

    return (
      favs: [
        for (final f in store.favorites)
          if (same(f.title)) f
      ],
      hist: [
        for (final h in store.history)
          if (same(h.title)) h
      ],
    );
  }

  /// 把标题解析成「作品分组 key」:优先复用已出现的同作品 key(sameCoreKey 容繁简/副标题)。
  static String _canonKey(String core, Iterable<String> existing) {
    for (final k in existing) {
      if (k == core || sameCoreKey(core, k)) return k;
    }
    return core;
  }

  /// 作品分组 key → 拥有该作品的源集合(收藏 ∪ 历史)。是分组的**权威 key 来源**。
  static Map<String, Set<String>> _sourcesByWork(LibraryStore store) {
    final m = <String, Set<String>>{};
    void add(String title, String sid) {
      final core = coreTitle(title);
      if (core.isEmpty) return;
      (m[_canonKey(core, m.keys)] ??= <String>{}).add(sid);
    }

    for (final f in store.favorites) {
      add(f.title, f.sourceId);
    }
    for (final h in store.history) {
      add(h.title, h.sourceId);
    }
    return m;
  }
}
