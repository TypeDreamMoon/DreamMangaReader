import 'package:flutter/material.dart';

import '../../app/anime_library_store.dart';
import '../../app/library_store.dart';
import '../../app/novel_library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/source_search.dart';
import '../../ui/ui.dart';
import '../anime/anime_detail_page.dart';
import '../anime/anime_history_resume.dart';
import '../common/transitions.dart';
import '../detail/detail_page.dart';
import '../novel/novel_import_sheet.dart';
import '../novel/novel_library_view.dart';
import 'history_page.dart';
import 'masonry_feed.dart';
import 'shelf_card.dart';
import 'shelf_item.dart';
import 'unified_history.dart';

/// 书架:**我的收藏与历史**。
///
/// 漫画、小说、番剧三类同级 —— 顶部一条类型筛选,下面是一条统一「历史记录」横条
/// 和一个统一「收藏」网格(混排时封面左下带类型角标)。三类共用同一套卡片与布局
/// (瀑布流/网格/列表跟随设置),不再是「漫画全宽网格 + 两条 92px 附属横条」。
///
/// 浏览新内容(混合源发现流、为你推荐)归发现页,书架不再承担。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  /// 类型筛选;null = 全部(三类混排)。
  ShelfKind? _kind;

  final TextEditingController _searchCtrl = TextEditingController();
  bool _showSearch = false;
  String _query = ''; // 非空 = 在收藏里筛选
  final ScrollController _historyScroll = ScrollController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    _historyScroll.dispose();
    super.dispose();
  }

  // ---- 打开条目 ----

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  bool _crossOpening = false; // 同名查找进行中(防连点重复扇出)

  /// 在(除 [excludeSourceId] 外的)启用漫画源里搜同名并打开详情页。
  Future<void> _openInOtherSource(String title,
      {String? excludeSourceId}) async {
    if (_crossOpening) return;
    final store = LibraryScope.read(context);
    final metas = [
      for (final s in registeredSources)
        if (s.kind == 'manga' &&
            store.isSourceEnabled(s.id) &&
            s.id != excludeSourceId)
          s
    ];
    if (metas.isEmpty) {
      _snack(context.l10n.detail_noOtherSources);
      return;
    }
    _crossOpening = true;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.l10n.shelf_searchingInOtherTitle(title)),
        duration: const Duration(seconds: 20), // 找到/失败会主动收掉
      ));
    }
    try {
      final r = await findFirstWork(metas, title);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      // 搜索期间用户已经点开别的页面 → 别把陈旧结果压到人家头上。
      if (ModalRoute.of(context)?.isCurrent != true) return;
      final m = r.match;
      if (m == null) {
        _snack(r.allErrored
            ? context.l10n.shelf_allSourcesSearchFailed
            : context.l10n.detail_noSameNameInOthers);
        return;
      }
      Navigator.of(context)
          .push(appRoute(DetailPage(manga: m.manga, meta: m.meta)));
    } finally {
      _crossOpening = false;
    }
  }

  /// 打开一条漫画收藏:源还在直接开;**源被删/不存在就自动在其它源找同名**打开
  /// (收藏不再因为删了源而变成死卡片)。
  void _openManga({
    required String title,
    required String sourceId,
    required String mangaId,
    String? cover,
    Object? heroTag,
  }) {
    final meta = sourceMetaById(sourceId);
    if (meta == null) {
      _openInOtherSource(title, excludeSourceId: sourceId);
      return;
    }
    Navigator.of(context).push(appRoute(DetailPage(
      manga: Manga(id: mangaId, title: title, cover: cover),
      meta: meta,
      heroTag: heroTag,
    )));
  }

  void _openAnime(AnimeFavoriteEntry entry, {Object? heroTag}) {
    final meta = sourceMetaById(entry.sourceId);
    if (meta == null) {
      _snack(context.l10n.shelf_sourceGone(sourceNameOf(entry.sourceId)));
      return;
    }
    Navigator.of(context).push(appRoute(AnimeDetailPage(
      meta: meta,
      anime: Manga(id: entry.animeId, title: entry.title, cover: entry.cover),
      heroTag: heroTag,
    )));
  }

  /// 书架卡片的统一打开入口:按类型派发到各自的详情/阅读入口。
  void _openItem(ShelfItem item, {Object? heroTag}) {
    switch (item.kind) {
      case ShelfKind.manga:
        final f = item.mangaEntry!;
        _openManga(
          title: f.title,
          sourceId: f.sourceId,
          mangaId: f.mangaId,
          cover: f.cover,
          heroTag: heroTag,
        );
      case ShelfKind.novel:
        final entry = item.novelEntry!;
        if (!entry.available) {
          _snack(context.l10n.novel_fileMissing);
          return;
        }
        openNovelLibraryEntry(context, entry, heroTag: heroTag);
      case ShelfKind.anime:
        _openAnime(item.animeEntry!, heroTag: heroTag);
    }
  }

  // ---- 卡片右键(桌面)/长按(触屏)菜单 ----

  /// 漫画条目按「作品」操作:去重卡代表的是跨源同一部书,取消收藏/删记录作用于该作品
  /// 在**所有源**的条目,卡片才会消失。小说/番剧无跨源去重,按条操作。
  Future<void> _showItemMenu(ShelfItem item, Offset pos) async {
    final p = context.palette;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    PopupMenuItem<String> entry(String v, IconData ic, String label,
            {Color? color}) =>
        PopupMenuItem<String>(
          value: v,
          height: 42,
          child: Row(children: [
            Icon(ic, size: 17, color: color ?? p.textMuted),
            const SizedBox(width: 10),
            Text(label,
                style:
                    TextStyle(fontSize: 13.5, color: color ?? p.textPrimary)),
          ]),
        );

    final mangaStore = LibraryScope.read(context);
    final fav = item.mangaEntry;
    final work = fav == null
        ? null
        : ShelfProjector.workEntries(mangaStore, fav.title,
            sourceId: fav.sourceId, mangaId: fav.mangaId);
    final localNovel = item.novelEntry?.isLocal ?? false;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy,
          overlay.size.width - pos.dx, overlay.size.height - pos.dy),
      color: p.elevated,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: p.line)),
      items: [
        entry('open', Icons.menu_book_rounded, context.l10n.shelf_menuOpen),
        if (item.kind == ShelfKind.manga)
          entry('other', Icons.swap_horiz_rounded,
              context.l10n.shelf_menuOpenOther),
        entry(
          'unfav',
          localNovel
              ? Icons.delete_outline_rounded
              : Icons.favorite_border_rounded,
          localNovel
              ? context.l10n.novel_deleteLocal
              : context.l10n.shelf_menuUnfav,
          color: p.statusFail,
        ),
        if (work != null && work.hist.isNotEmpty)
          entry('delhist', Icons.delete_outline_rounded,
              context.l10n.shelf_menuDelHist,
              color: p.statusFail),
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'open':
        _openItem(item);
      case 'other':
        _openInOtherSource(fav!.title, excludeSourceId: fav.sourceId);
      case 'unfav':
        await _unfavorite(item);
      case 'delhist':
        for (final h in work!.hist) {
          mangaStore.removeHistory(h.sourceId, h.mangaId);
        }
        _snack(context.l10n.shelf_histDeleted);
    }
  }

  Future<void> _unfavorite(ShelfItem item) async {
    switch (item.kind) {
      case ShelfKind.manga:
        final store = LibraryScope.read(context);
        final f = item.mangaEntry!;
        final work = ShelfProjector.workEntries(store, f.title,
            sourceId: f.sourceId, mangaId: f.mangaId);
        for (final e in work.favs) {
          store.toggleFavorite(e);
        }
        _snack(work.favs.length > 1
            ? context.l10n.shelf_unfavedN(work.favs.length)
            : context.l10n.shelf_unfaved);
      case ShelfKind.novel:
        final store = NovelLibraryScope.read(context);
        final entry = item.novelEntry!;
        // 本地导入的小说没有「取消收藏」语义 —— 它就是书架里的那本书,只能删。
        if (entry.isLocal) {
          await _confirmDeleteLocalNovel(store, entry);
          return;
        }
        store.toggleRemoteFavorite(entry);
        _snack(context.l10n.shelf_unfaved);
      case ShelfKind.anime:
        AnimeLibraryScope.read(context).toggleFavorite(item.animeEntry!);
        _snack(context.l10n.shelf_unfaved);
    }
  }

  Future<void> _confirmDeleteLocalNovel(
      NovelLibraryStore store, NovelLibraryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.novel_deleteLocalTitle),
        content: Text(entry.available
            ? dialogContext.l10n.novel_deleteLocalConfirm(entry.title)
            : dialogContext.l10n.novel_deleteMissingConfirm(entry.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final path = entry.privatePath;
      if (entry.available && path != null) {
        await deleteLocalNovelDirectory(path);
      }
      store.removeLocal(entry.key, removeHistory: true);
    } catch (error) {
      if (mounted) _snack(context.l10n.novel_deleteFailed('$error'));
    }
  }

  // ---- 页面 ----

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 依赖三个 store:收藏/进度变了自动重建。
    final mangaStore = LibraryScope.of(context);
    final novelStore = NovelLibraryScope.of(context);
    final animeStore = AnimeLibraryScope.of(context);
    // 一次投影出全部收藏(漫画跨源去重不便宜),筛选条计数与网格都从它派生。
    final all = ShelfProjector.build(
      manga: mangaStore,
      novel: novelStore,
      anime: animeStore,
    );
    final q = _query.toLowerCase();
    final items = [
      for (final item in all)
        if ((_kind == null || item.kind == _kind) &&
            (q.isEmpty || item.matches(q)))
          item
    ];
    // 搜索时历史条让位,不必白算一遍。
    final history = _query.isEmpty
        ? _history(mangaStore, novelStore, animeStore)
        : const <UnifiedHistoryItem>[];
    // 内容延伸到毛玻璃标题栏之后 → 标题栏能糊到身后背景图;body 手动留出顶部内边距。
    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: Text(context.l10n.navBookshelf,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          IconButton(
            tooltip: context.l10n.shelf_searchInFavsTooltip,
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _searchCtrl.clear();
                _query = '';
              }
            }),
            icon: Icon(
                _showSearch ? Icons.search_off_rounded : Icons.search_rounded),
          ),
          const NovelImportButton(compact: true),
          IconButton(
            tooltip: context.l10n.shelf_historyTooltip,
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const HistoryPage())),
            icon: const Icon(Icons.history_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      // 内容自下而上升起(标题栏则自上而下落,合成「上下对开」入场)。
      body: EntranceSlide(
        begin: const Offset(0, 0.06),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: Column(
            children: [
              _kindFilter(p, all),
              // 搜索框展开/收起用高度动画,避免书架内容硬跳。
              AnimatedSize(
                duration: LibraryStore.animationsEnabled
                    ? const Duration(milliseconds: 220)
                    : Duration.zero,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _showSearch
                    ? _searchField(p)
                    : const SizedBox(width: double.infinity),
              ),
              Expanded(
                child: AppScrollView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    // 搜索时只留结果,历史条让位。
                    if (_query.isEmpty) _historySection(p, history),
                    _favoritesSection(p, mangaStore, items),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 三类历史统一按时间排序;[_kind] 选中某类时只留该类。
  List<UnifiedHistoryItem> _history(
    LibraryStore mangaStore,
    NovelLibraryStore novelStore,
    AnimeLibraryStore animeStore,
  ) {
    final all = UnifiedHistoryProjector.build(
      manga: mangaStore.history,
      novel: [
        for (final item in novelStore.history)
          if (novelStore.entryFor(item.key) case final entry?)
            UnifiedNovelHistoryInput(entry: entry, progress: item.value),
      ],
      anime: animeStore.history,
    );
    final want = switch (_kind) {
      null => null,
      ShelfKind.manga => UnifiedHistoryKind.manga,
      ShelfKind.novel => UnifiedHistoryKind.novel,
      ShelfKind.anime => UnifiedHistoryKind.anime,
    };
    if (want == null) return all;
    return [
      for (final item in all)
        if (item.kind == want) item
    ];
  }

  // ---- 类型筛选 ----

  Widget _kindFilter(AppPalette p, List<ShelfItem> all) {
    final counts = <ShelfKind, int>{};
    for (final item in all) {
      counts[item.kind] = (counts[item.kind] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _kindChip(p, null, context.l10n.libraryKindAll, Icons.apps_rounded,
              all.length),
          for (final kind in ShelfKind.values)
            _kindChip(p, kind, shelfKindLabel(context, kind),
                shelfKindIcon(kind), counts[kind] ?? 0),
        ],
      ),
    );
  }

  Widget _kindChip(
      AppPalette p, ShelfKind? kind, String label, IconData icon, int count) {
    final sel = _kind == kind;
    return GestureDetector(
      key: ValueKey('shelf-kind-${kind?.name ?? 'all'}'),
      onTap: () {
        if (_kind == kind) return;
        setState(() => _kind = kind);
      },
      child: AnimatedContainer(
        duration: LibraryStore.animationsEnabled
            ? const Duration(milliseconds: 160)
            : Duration.zero,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? p.accent.withValues(alpha: 0.16) : p.surface,
          borderRadius: BorderRadius.circular(context.radius),
          border:
              Border.all(color: sel ? p.accent : p.line, width: sel ? 1.5 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: sel ? p.accent : p.textMuted),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: sel ? p.accent : p.textPrimary,
                    fontSize: 12.5,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Text('$count',
                  style: TextStyle(
                      color: sel ? p.accent : p.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _searchField(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: TextField(
          controller: _searchCtrl,
          autofocus: true,
          style: TextStyle(color: p.textPrimary, fontSize: 14),
          onChanged: (v) => setState(() => _query = v.trim()),
          decoration: InputDecoration(
            isDense: true,
            hintText: context.l10n.shelf_searchInFavsHint,
            hintStyle: TextStyle(color: p.textMuted, fontSize: 13),
            prefixIcon:
                Icon(Icons.search_rounded, size: 18, color: p.textMuted),
            filled: true,
            fillColor: p.surface,
            contentPadding:
                const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: p.line)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: p.accent)),
          ),
        ),
      );

  // ---- 历史记录横条 ----

  Widget _historySection(AppPalette p, List<UnifiedHistoryItem> history) {
    final items = history.take(12).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
          child: Row(
            children: [
              Expanded(
                child: AppSectionHeading(context.l10n.libraryUnifiedHistory),
              ),
              IconButton(
                tooltip: context.l10n.shelf_historyTooltip,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const HistoryPage()),
                ),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
        if (items.isEmpty)
          _compactEmpty(p, context.l10n.libraryHistoryEmpty)
        else
          SizedBox(
            height: 172,
            // 桌面滚轮/鼠标拖拽可横滑(AppHStrip 统一处理)。
            child: AppHStrip.separated(
              controller: _historyScroll,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) => _historyCard(p, items[index]),
            ),
          ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _historyCard(AppPalette p, UnifiedHistoryItem item) {
    late final ShelfKind kind;
    late final String id;
    late final String progress;
    String? sourceId;
    List<String> authors = const [];
    VoidCallback? onTap;
    switch (item.kind) {
      case UnifiedHistoryKind.manga:
        final h = item.manga!;
        kind = ShelfKind.manga;
        id = h.mangaId;
        sourceId = h.sourceId;
        progress = h.lastChapterName;
        onTap = () => _openManga(
              title: h.title,
              sourceId: h.sourceId,
              mangaId: h.mangaId,
              cover: h.cover,
            );
      case UnifiedHistoryKind.novel:
        final entry = item.novelEntry!;
        kind = ShelfKind.novel;
        id = entry.novelId ?? entry.fingerprint ?? entry.key;
        authors = entry.authors;
        progress = item.novelProgress!.locator.chapterId;
        if (entry.available) {
          onTap = () => openNovelLibraryEntry(context, entry);
        }
      case UnifiedHistoryKind.anime:
        final h = item.anime!;
        kind = ShelfKind.anime;
        id = h.animeId;
        sourceId = h.sourceId;
        progress = context.l10n.animeHistoryProgress(
          h.episodeName,
          formatShelfClock(h.positionSeconds),
          h.durationSeconds > 0
              ? formatShelfClock(h.durationSeconds)
              : '--:--',
        );
        onTap = () => openAnimeHistory(context, h);
    }
    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: shelfCoverWithBadge(
              // 全部混排时才标类型;已按类型筛选过就是噪音。
              showKind: _kind == null,
              kind: kind,
              cover: ShelfCover(
                kind: kind,
                id: id,
                title: item.title,
                cover: item.cover,
                authors: authors,
                sourceId: sourceId,
                radius: 8,
                onTap: onTap,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.25,
              fontWeight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          Text(
            progress,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, height: 1.25, color: p.accentSoft),
          ),
        ],
      ),
    );
  }

  // ---- 统一收藏网格 ----

  Widget _favoritesSection(
      AppPalette p, LibraryStore store, List<ShelfItem> items) {
    final layout = store.feedLayout;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 25),
          child: AppSectionHeading(
            items.isEmpty
                ? context.l10n.libraryFavorites
                : context.l10n.shelf_favoritesN(items.length),
          ),
        ),
        if (items.isEmpty)
          _compactEmpty(p, _emptyText())
        else
          FeedView(
            layout: layout,
            shrinkWrap: true, // 嵌在书架外层 ListView 里,自身不滚
            columns: store.gridColumns,
            itemCount: items.length,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            cardBuilder: (context, i) => _shelfCard(p, items[i], layout),
            tileBuilder: (context, i) => _shelfTile(p, items[i]),
          ),
      ],
    );
  }

  String _emptyText() {
    if (_query.isNotEmpty) return context.l10n.shelf_noFavMatch(_query);
    return switch (_kind) {
      null => context.l10n.libraryFavoritesEmpty,
      ShelfKind.manga => context.l10n.libraryMangaFavoritesEmpty,
      ShelfKind.novel => context.l10n.libraryNovelFavoritesEmpty,
      ShelfKind.anime => context.l10n.libraryAnimeFavoritesEmpty,
    };
  }

  /// 副标题:小说给作者,漫画/番剧给来源名。网格是定高单元格,恒占一行让各卡对齐。
  String _subtitleOf(ShelfItem item) {
    final text = switch (item.kind) {
      ShelfKind.novel => item.subtitle,
      ShelfKind.manga => sourceNameOf(item.mangaEntry!.sourceId),
      ShelfKind.anime => sourceNameOf(item.animeEntry!.sourceId),
    };
    return text.isEmpty ? ' ' : text;
  }

  /// 右键(桌面)/长按(触屏)唤出条目菜单。
  Widget _withMenu({required ShelfItem item, required Widget child}) =>
      GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (d) => _showItemMenu(item, d.globalPosition),
        onSecondaryTapUp: (d) => _showItemMenu(item, d.globalPosition),
        child: child,
      );

  // 收藏卡(瀑布流/网格):封面 + 类型角标 + 标题 + 副标题。
  // 网格用 Flexible 防固定高单元格溢出;瀑布流取自然高。
  Widget _shelfCard(AppPalette p, ShelfItem item, FeedLayout layout) {
    final tag = 'shelf:${item.key}';
    final cover = shelfCoverWithBadge(
      showKind: _kind == null,
      kind: item.kind,
      cover: ShelfCover.item(
        item,
        // 瀑布流:按 id 派生高低错落;网格:统一 3:4。
        aspect: layout == FeedLayout.masonry
            ? aspectForId(shelfItemId(item))
            : 3 / 4,
        heroTag: tag,
        onTap: () => _openItem(item, heroTag: tag),
      ),
    );
    return _withMenu(
      item: item,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          layout == FeedLayout.grid ? Flexible(child: cover) : cover,
          const SizedBox(height: 6),
          Text(item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: p.textPrimary)),
          Text(_subtitleOf(item),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: p.textMuted)),
        ],
      ),
    );
  }

  // 收藏行(列表布局):横排封面 + 标题 / 副标题 / 类型。
  Widget _shelfTile(AppPalette p, ShelfItem item) {
    final tag = 'shelfl:${item.key}';
    return _withMenu(
      item: item,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AppCard(
          padding: const EdgeInsets.all(9),
          onTap: () => _openItem(item, heroTag: tag),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: ShelfCover.item(item, radius: 8, heroTag: tag),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 14,
                            height: 1.25,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        ShelfKindBadge(kind: item.kind),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_subtitleOf(item),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: p.textMuted, fontSize: 11.5)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.chevron_right_rounded,
                    size: 18, color: p.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _compactEmpty(AppPalette p, String message) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          message,
          style: TextStyle(color: p.textMuted, fontSize: 12.5),
        ),
      );
}

/// 秒 → `h:mm:ss` / `mm:ss`(番剧续播进度)。
String formatShelfClock(int totalSeconds) {
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final tail = '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$tail' : tail;
}
