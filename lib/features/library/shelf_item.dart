import 'package:flutter/foundation.dart' show visibleForTesting;

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
  /// 分组时做过多少次 [sameCoreKey] 比较。测试用它守住「别再退回平方级」。
  @visibleForTesting
  static int debugWorkKeyComparisons = 0;

  /// [build] 真正跑了多少次。书架页会缓存结果,测试用它守住缓存别白建。
  @visibleForTesting
  static int debugBuildCount = 0;

  /// 三类收藏合并成一条按**收藏时间倒序**的列表。
  /// [kind] 非空则只出该类;[query] 非空则按标题/作者过滤。
  static List<ShelfItem> build({
    required LibraryStore manga,
    required NovelLibraryStore novel,
    required AnimeLibraryStore anime,
    ShelfKind? kind,
    String query = '',
  }) {
    debugBuildCount++;
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
    final (:sources, :index) = _sourcesByWork(store); // 权威分组 key + 索引
    final groups = <String, List<FavoriteEntry>>{}; // 插入序 = 收藏序(最近在前)
    for (final f in store.favorites) {
      final core = coreTitle(f.title);
      // 索引已由 _sourcesByWork 建好,这一遍纯查表(以前是又一次全表线性扫)。
      final key = core.isEmpty ? 'raw:${f.key}' : index.lookup(core);
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
      out.add((rep: rep, sources: sources[key]?.length ?? 1));
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

  /// 作品分组 key → 拥有该作品的源集合(收藏 ∪ 历史)。是分组的**权威 key 来源**;
  /// 一并返回建好的索引,给第二遍(按收藏分组)查表用。
  static ({Map<String, Set<String>> sources, _WorkKeyIndex index})
      _sourcesByWork(LibraryStore store) {
    final m = <String, Set<String>>{};
    final index = _WorkKeyIndex();
    void add(String title, String sid) {
      final core = coreTitle(title);
      if (core.isEmpty) return;
      (m[index.canonical(core)] ??= <String>{}).add(sid);
    }

    for (final f in store.favorites) {
      add(f.title, f.sourceId);
    }
    for (final h in store.history) {
      add(h.title, h.sourceId);
    }
    return (sources: m, index: index);
  }
}

/// 「标题 → 作品分组 key」的索引。
///
/// 以前是拿每个新标题去跟**所有**已出现的 key 逐个 [sameCoreKey] —— 书架一大就是
/// 平方级,而书架每次 build、搜索框每敲一个字都要重算一遍。
///
/// 这里按 [sameCoreKey] 的两条硬条件建倒排桶把候选集压到个位数:
/// 1. 长度必须相同(变体是逐字替换,续作/卷号是加后缀,长度就变了);
/// 2. 至少共用一个字(判定要求 ≥70% 字符重叠,非空标题必有交集)。
/// 再叠一层 [_canon] 缓存:跨源同一本书(最常见的情况)直接命中,一次比较都不做。
///
/// 语义与旧实现逐字一致 —— 候选集是旧实现扫描集合的超集里唯一可能命中的部分,
/// 并按登记先后取第一个命中的 key。
class _WorkKeyIndex {
  final Map<String, String> _canon = {}; // core → 权威 key(含已判定的变体)
  final Map<String, List<String>> _buckets = {}; // '长度|字' → 该桶里的权威 key
  final Map<String, int> _order = {}; // 权威 key → 登记序(取「最早命中的那个」)

  static Iterable<String> _bucketsOf(String core) {
    final seen = <String>{};
    final out = <String>[];
    for (final ch in core.split('')) {
      if (seen.add(ch)) out.add('${core.length}|$ch');
    }
    return out;
  }

  /// 解析 [core] 的分组 key;没见过就把它自己登记成新的权威 key。
  String canonical(String core) {
    final cached = _canon[core];
    if (cached != null) return cached;
    String? best;
    var bestOrder = -1;
    for (final b in _bucketsOf(core)) {
      for (final k in _buckets[b] ?? const <String>[]) {
        final o = _order[k]!;
        if (best != null && o >= bestOrder) continue; // 已有更早的命中
        ShelfProjector.debugWorkKeyComparisons++;
        if (sameCoreKey(core, k)) {
          best = k;
          bestOrder = o;
        }
      }
    }
    final hit = best;
    if (hit != null) return _canon[core] = hit;
    _order[core] = _order.length;
    for (final b in _bucketsOf(core)) {
      (_buckets[b] ??= <String>[]).add(core);
    }
    return _canon[core] = core;
  }

  /// 索引建好之后只查不建(第二遍回填分组用)。
  String lookup(String core) => _canon[core] ?? core;
}
