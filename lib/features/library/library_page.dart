import 'package:flutter/material.dart';

import '../../app/anime_library_store.dart';
import '../../app/library_store.dart';
import '../../app/novel_library_store.dart';
import '../../app/source_controller.dart';
import '../../app/theme/app_colors.dart';
import '../../core/novel/models.dart';
import '../../core/source/chinese_fold.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart' show MangaSource;
import '../../core/l10n/app_strings.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/source_search.dart';
import '../../core/source/title_match.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import '../common/source_picker.dart';
import '../common/transitions.dart';
import '../detail/detail_page.dart';
import '../anime/anime_detail_page.dart';
import '../anime/anime_history_resume.dart';
import '../novel/novel_import_sheet.dart';
import '../novel/novel_cover.dart';
import '../novel/novel_library_view.dart';
import 'history_page.dart';
import 'manga_cover.dart';
import 'masonry_feed.dart';
import 'recommend_controller.dart';
import 'unified_history.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({
    super.key,
    this.recommendController,
  });

  final RecommendController? recommendController;

  @override
  Widget build(BuildContext context) => _MangaLibraryPage(
        recommendController: recommendController,
      );
}

/// 保留原漫画书架的推荐和跨源能力，在同一页面加入三类收藏与统一历史。
class _MangaLibraryPage extends StatefulWidget {
  const _MangaLibraryPage({this.recommendController});

  final RecommendController? recommendController;

  @override
  State<_MangaLibraryPage> createState() => _MangaLibraryPageState();
}

class _MangaLibraryPageState extends State<_MangaLibraryPage> {
  SourceController? _sc;

  // ---- 底部「推荐」浏览区(默认混合源;开了「显示源选择器」= 单源可切)----
  List<({Manga manga, SourceMeta meta})> _feedItems = [];
  final Map<String, int> _feedPos = {}; // 归一化标题 → 卡片下标(去重)
  final Map<String, Set<String>> _feedSrc = {}; // 归一化标题 → 源集合(N源角标)
  bool _feedLoading = false;
  String? _feedError; // 只有所有源都失败才展示
  int _feedOk = 0; // 本轮成功返回的源数
  int _feedGen = 0;
  bool? _feedMixed; // 当前一轮是混合还是单源(设置切换时重拉)
  static const _feedCap = 60; // 混合模式卡片上限(嵌在书架里,别无限长)

  final TextEditingController _shelfCtrl = TextEditingController();
  bool _showShelfSearch = false;
  String _shelfQuery = ''; // 非空 = 在收藏里筛选
  final ScrollController _continueScroll = ScrollController();
  final ScrollController _recScroll = ScrollController();
  late final RecommendController _recs =
      widget.recommendController ?? RecommendController();
  String _lastRecSig = ''; // 上次触发推荐刷新时的书架签名(变了才重触发)

  @override
  void dispose() {
    _sc?.removeListener(_onSourceChanged);
    _shelfCtrl.dispose();
    _continueScroll.dispose();
    _recScroll.dispose();
    if (widget.recommendController == null) _recs.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sc = SourceScope.of(context);
    if (sc != _sc) {
      _sc?.removeListener(_onSourceChanged);
      _sc = sc..addListener(_onSourceChanged);
      _loadFeed();
    }
  }

  void _onSourceChanged() => setState(_loadFeed);

  /// 重拉底部浏览区。默认**混合源**:所有启用的漫画源各拉第一页,谁先到谁先上,
  /// 同名(容繁简)去重合成一张卡 + 「N源」角标;单源失败不拖累其它源。
  /// 开了「显示源选择器」则退回单源模式(与发现页语义一致)。
  /// 同步段只改字段不 setState(didChangeDependencies 里也能安全调),
  /// 需要立即重绘的调用方用 `setState(_loadFeed)`。
  void _loadFeed() {
    final gen = ++_feedGen;
    _feedItems = [];
    _feedPos.clear();
    _feedSrc.clear();
    _feedError = null;
    _feedOk = 0;
    final store = LibraryScope.read(context);
    final mixed = !store.showSourcePicker;
    _feedMixed = mixed;
    final cur = _sc?.current;
    final metas = mixed
        ? [
            for (final s in registeredSources)
              if (s.kind == 'manga' && store.isSourceEnabled(s.id)) s
          ]
        : [if (cur != null) cur];
    if (metas.isEmpty) {
      _feedLoading = false;
      return; // 没有可用源:外层 meta==null 已走空态提示
    }
    var pending = metas.length;
    _feedLoading = true;
    for (final meta in metas) {
      // Future(...) 包一层:每个源的脚本 eval(buildSource,同步且不便宜)排到
      // 各自的事件循环轮次,不在同一帧里连评 N 个脚本卡住 UI。
      Future(() async {
        MangaSource? src;
        List<Manga> items = const [];
        var ok = false;
        try {
          if (!mounted || gen != _feedGen) return; // 排队期间已换代:别白建引擎
          src = buildSource(meta);
          final page = await src.getDiscovery(1);
          items = page.items;
          ok = true;
        } catch (e) {
          if (gen == _feedGen) _feedError ??= '$e';
        } finally {
          src?.dispose();
        }
        if (!mounted || gen != _feedGen) return;
        setState(() {
          if (ok) {
            _feedOk++;
            _ingestFeed(meta, items);
          }
          if (--pending == 0) _feedLoading = false;
        });
      });
    }
  }

  /// 一批结果按「繁→简折叠 + 归一化标题」去重并入:新标题出卡(记源为代表),
  /// 已有的只累加源 id(驱动「N源」角标)。超过 [_feedCap] 不再出新卡。
  void _ingestFeed(SourceMeta meta, List<Manga> items) {
    for (final m in items) {
      final key = ChineseFold.dedupKey(m.title);
      if (key.isEmpty) {
        if (_feedItems.length < _feedCap) {
          _feedItems.add((manga: m, meta: meta));
        }
        continue;
      }
      final pos = _feedPos[key];
      if (pos == null) {
        if (_feedItems.length >= _feedCap) continue;
        _feedPos[key] = _feedItems.length;
        _feedSrc[key] = {meta.id};
        _feedItems.add((manga: m, meta: meta));
      } else {
        (_feedSrc[key] ??= {}).add(meta.id);
      }
    }
  }

  void _refresh() => setState(_loadFeed);

  SourceMeta? _metaById(String id) {
    for (final s in registeredSources) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _openManga(Manga m, SourceMeta meta, {Object? heroTag}) =>
      Navigator.of(context).push(
        appRoute(DetailPage(manga: m, meta: meta, heroTag: heroTag)),
      );

  // ---- 智能打开(源被删自动找同名换源)+ 卡片右键/长按菜单 ----

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
      _openManga(m.manga, m.meta);
    } finally {
      _crossOpening = false;
    }
  }

  /// 打开一个书架条目:源还在直接开;**源被删/不存在就自动在其它源找同名**打开
  /// (收藏不再因为删了源而变成死卡片)。
  void _openEntrySmart({
    required String title,
    required String sourceId,
    required String mangaId,
    String? cover,
    Object? heroTag,
  }) {
    final meta = _metaById(sourceId);
    if (meta != null) {
      _openManga(Manga(id: mangaId, title: title, cover: cover), meta,
          heroTag: heroTag);
      return;
    }
    _openInOtherSource(title, excludeSourceId: sourceId);
  }

  /// 同一作品(容繁简/装饰副标题,与书架去重同口径)的全部收藏与历史条目。
  /// 标题归一化为空(纯符号名)时书架也是按单条出卡的,组操作只作用于被点的
  /// 那一条([sourceId]:[mangaId]),不能按字面标题误伤其它同符号名的书。
  ({List<FavoriteEntry> favs, List<ReadState> hist}) _workEntries(
      LibraryStore store, String title,
      {required String sourceId, required String mangaId}) {
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

  /// 卡片右键(桌面)/长按(触屏)菜单。条目按「作品」操作:去重卡代表的是
  /// 跨源同一部书,取消收藏/删记录作用于该作品在**所有源**的条目,卡片才会消失。
  Widget _withEntryMenu({
    required Widget child,
    required String title,
    required String sourceId,
    required String mangaId,
    String? cover,
    Object? heroTag,
  }) =>
      GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (d) => _showEntryMenu(d.globalPosition,
            title: title,
            sourceId: sourceId,
            mangaId: mangaId,
            cover: cover,
            heroTag: heroTag),
        onSecondaryTapUp: (d) => _showEntryMenu(d.globalPosition,
            title: title,
            sourceId: sourceId,
            mangaId: mangaId,
            cover: cover,
            heroTag: heroTag),
        child: child,
      );

  Future<void> _showEntryMenu(
    Offset pos, {
    required String title,
    required String sourceId,
    required String mangaId,
    String? cover,
    Object? heroTag,
  }) async {
    final p = context.palette;
    final store = LibraryScope.read(context);
    final w = _workEntries(store, title, sourceId: sourceId, mangaId: mangaId);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    PopupMenuItem<String> item(String v, IconData ic, String label,
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
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy,
          overlay.size.width - pos.dx, overlay.size.height - pos.dy),
      color: p.elevated,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: p.line)),
      items: [
        item('open', Icons.menu_book_rounded, context.l10n.shelf_menuOpen),
        item('other', Icons.swap_horiz_rounded,
            context.l10n.shelf_menuOpenOther),
        if (w.favs.isNotEmpty)
          item('unfav', Icons.favorite_border_rounded,
              context.l10n.shelf_menuUnfav,
              color: p.statusFail),
        if (w.hist.isNotEmpty)
          item('delhist', Icons.delete_outline_rounded,
              context.l10n.shelf_menuDelHist,
              color: p.statusFail),
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'open':
        _openEntrySmart(
            title: title,
            sourceId: sourceId,
            mangaId: mangaId,
            cover: cover,
            heroTag: heroTag);
      case 'other':
        _openInOtherSource(title, excludeSourceId: sourceId);
      case 'unfav':
        for (final f in w.favs) {
          store.toggleFavorite(f);
        }
        _snack(w.favs.length > 1
            ? context.l10n.shelf_unfavedN(w.favs.length)
            : context.l10n.shelf_unfaved);
      case 'delhist':
        for (final h in w.hist) {
          store.removeHistory(h.sourceId, h.mangaId);
        }
        _snack(context.l10n.shelf_histDeleted);
    }
  }

  // ---- 多源同名去重(书架把同一作品的多源副本合成一张卡;容繁简 + 副标题)----

  /// 把标题解析成「作品分组 key」:优先复用已出现的同作品 key(sameCoreKey 容繁简/副标题)。
  String _canonKey(String core, Iterable<String> existing) {
    for (final k in existing) {
      if (k == core || sameCoreKey(core, k)) return k;
    }
    return core;
  }

  /// 作品分组 key → 拥有该作品的源集合(收藏 ∪ 历史)。是分组的**权威 key 来源**。
  Map<String, Set<String>> _sourcesByWork(LibraryStore store) {
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

  /// 收藏去重:同作品合成一组,代表优先「最后阅读的源」的那条(没有则最近收藏的)。
  List<({FavoriteEntry rep, int sources})> _dedupFavs(LibraryStore store) {
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

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = LibraryScope.of(context); // 依赖:收藏/进度变了自动重建
    final novelStore = NovelLibraryScope.of(context);
    final animeStore = AnimeLibraryScope.of(context);
    final unifiedHistory = UnifiedHistoryProjector.build(
      manga: store.history,
      novel: [
        for (final item in novelStore.history)
          if (novelStore.entryFor(item.key) case final entry?)
            UnifiedNovelHistoryInput(entry: entry, progress: item.value),
      ],
      anime: animeStore.history,
    );
    final meta = _sc?.current; // 可能未配置源 → null
    // 书架内容变了(签名变)才后台重算「为你推荐」;post-frame 触发,避免 build 期改 controller。
    final recSig = RecommendController.signatureOf(store);
    if (recSig != _lastRecSig) {
      _lastRecSig = recSig;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recs.ensure(store);
      });
    }
    // 设置里切了「显示源选择器」(混合↔单源)→ 底部浏览区按新模式重拉。
    if (_feedMixed != null && _feedMixed != !store.showSourcePicker) {
      _feedMixed = !store.showSourcePicker;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_loadFeed);
      });
    }
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
              _showShelfSearch = !_showShelfSearch;
              if (!_showShelfSearch) {
                _shelfCtrl.clear();
                _shelfQuery = '';
              }
            }),
            icon: Icon(_showShelfSearch
                ? Icons.search_off_rounded
                : Icons.search_rounded),
          ),
          const NovelImportButton(compact: true),
          IconButton(
            tooltip: context.l10n.shelf_historyTooltip,
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const HistoryPage())),
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(
              onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
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
              // 搜索框展开/收起用高度动画,避免书架内容硬跳。
              AnimatedSize(
                duration: LibraryStore.animationsEnabled
                    ? const Duration(milliseconds: 220)
                    : Duration.zero,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _showShelfSearch
                    ? _shelfSearchField(p)
                    : const SizedBox(width: double.infinity),
              ),
              Expanded(
                child: _shelfQuery.isNotEmpty
                    ? _shelfResults(p, store, novelStore, animeStore)
                    : AppScrollView(
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [
                          _unifiedHistoryStrip(p, unifiedHistory),
                          _favoritesSection(p, store),
                          _novelFavoritesSection(p, novelStore),
                          _animeFavoritesSection(p, animeStore),
                          _recommendStrip(p, store),
                          if (meta != null) ...[
                            _sectionHeader(p, context.l10n.shelf_recommend),
                            if (store.showSourcePicker)
                              _sourcePicker(p, meta, store),
                            _browse(p, store),
                          ] else
                            _noSourceHint(p),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shelfSearchField(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: TextField(
          controller: _shelfCtrl,
          autofocus: true,
          style: TextStyle(color: p.textPrimary, fontSize: 14),
          onChanged: (v) => setState(() => _shelfQuery = v.trim()),
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

  Widget _shelfResults(
    AppPalette p,
    LibraryStore store,
    NovelLibraryStore novelStore,
    AnimeLibraryStore animeStore,
  ) {
    final q = _shelfQuery.toLowerCase();
    final favs = _dedupFavs(store)
        .where((e) => e.rep.title.toLowerCase().contains(q))
        .toList();
    final novels = novelStore.entries
        .where((entry) =>
            entry.favorite &&
            (entry.title.toLowerCase().contains(q) ||
                entry.authors
                    .any((author) => author.toLowerCase().contains(q))))
        .toList(growable: false);
    final anime = animeStore.favorites
        .where((entry) => entry.title.toLowerCase().contains(q))
        .toList(growable: false);
    if (favs.isEmpty && novels.isEmpty && anime.isEmpty) {
      return EmptyState(title: context.l10n.shelf_noFavMatch(_shelfQuery));
    }
    return AppScrollView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      children: [
        if (favs.isNotEmpty)
          _favoritesSection(
            p,
            store,
            favorites: favs,
            contentPadding: EdgeInsets.zero,
          ),
        if (novels.isNotEmpty)
          _novelFavoritesSection(
            p,
            novelStore,
            favorites: novels,
            contentPadding: EdgeInsets.zero,
          ),
        if (anime.isNotEmpty)
          _animeFavoritesSection(
            p,
            animeStore,
            favorites: anime,
            contentPadding: EdgeInsets.zero,
          ),
      ],
    );
  }

  Widget _sectionHeader(AppPalette p, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 25),
        child: AppSectionHeading(text),
      );

  // 推荐空态语义码 → 当前语言文案(控制器无 context,映射放这里)。
  String _recNoteText(BuildContext context, RecNote code) {
    final l = context.l10n;
    return switch (code) {
      RecNote.noRecsYet => l.rec_noRecsYet,
      RecNote.shelfTooEmpty => l.rec_shelfTooEmpty,
      RecNote.notEnoughBangumi => l.rec_notEnoughBangumi,
      RecNote.noSources => l.rec_noSources,
      RecNote.generateFailed => l.rec_generateFailed,
    };
  }

  // 「为你推荐」:据收藏 + 在读的口味算、混合源解析出的可读漫画横向条。无结果则不占位。
  Widget _recommendStrip(AppPalette p, LibraryStore store) => AnimatedBuilder(
        animation: _recs,
        builder: (_, __) {
          final recs = _recs.recs;
          final noteCode = _recs.noteCode;
          // 空态里只有「可重试」的提示(失败 / 暂时性)才占位显示 —— 「书架太少」这类
          // 需用户去收藏、重试无用的,直接不占位。
          final showNote = recs.isEmpty &&
              !_recs.loading &&
              noteCode != null &&
              _recs.canRetry;
          if (recs.isEmpty && !_recs.loading && !showNote) {
            return const SizedBox.shrink();
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 14),
                child: Row(
                  children: [
                    // Row 给子级无界宽度,带尾线(内部 Expanded)会炸布局 → 关掉尾线。
                    AppSectionHeading(context.l10n.shelf_forYou,
                        trailingRule: false),
                    const SizedBox(width: 10),
                    if (_recs.loading)
                      SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: p.accent)),
                    const Spacer(),
                    if (!_recs.loading)
                      Pressable(
                        onTap: () => _recs.ensure(store, force: true),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.refresh_rounded,
                              size: 18, color: p.textMuted),
                        ),
                      ),
                  ],
                ),
              ),
              if (recs.isEmpty && _recs.loading)
                SizedBox(
                  height: 56,
                  child: Center(
                    child: Text(context.l10n.shelf_generatingRecs,
                        style: TextStyle(color: p.textMuted, fontSize: 12)),
                  ),
                ),
              if (showNote)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Text(_recNoteText(context, noteCode),
                      style: TextStyle(color: p.textMuted, fontSize: 12.5)),
                ),
              if (recs.isNotEmpty)
                SizedBox(
                  height: 172,
                  // 桌面滚轮/鼠标拖拽可横滑(AppHStrip 统一处理)。
                  child: AppHStrip.separated(
                    controller: _recScroll,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: recs.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, i) => _recCard(p, recs[i]),
                  ),
                ),
            ],
          );
        },
      );

  Widget _recCard(AppPalette p, RecItem rec) {
    final m = rec.manga;
    final tag = 'rec:${rec.meta.id}:${m.id}';
    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: MangaCover(
              manga: m,
              headers: imageHeadersOf(rec.meta),
              heroTag: tag,
              onTap: () => Navigator.of(context).push(
                  appRoute(DetailPage(manga: m, meta: rec.meta, heroTag: tag))),
            ),
          ),
          const SizedBox(height: 6),
          Text(m.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
          if (rec.bgm.score > 0)
            Text('★ ${rec.bgm.score.toStringAsFixed(1)} · ${rec.meta.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textMuted, fontSize: 10.5)),
        ],
      ),
    );
  }

  // 未配置漫画源(引擎不内置源,需在设置里添加源仓库)的空态。
  Widget _noSourceHint(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Column(
          children: [
            Icon(Icons.travel_explore_rounded, size: 44, color: p.textMuted),
            const SizedBox(height: 14),
            Text(context.l10n.shelf_noSourceTitle,
                style: TextStyle(
                    color: p.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
            const SizedBox(height: 8),
            Text(context.l10n.shelf_noSourceDesc,
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: p.textMuted, fontSize: 13, height: 1.5)),
          ],
        ),
      );

  // 三类历史统一按时间排序，首页最多展示 12 条。
  Widget _unifiedHistoryStrip(
    AppPalette p,
    List<UnifiedHistoryItem> history,
  ) {
    final items = history.take(12).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
          child: Row(
            children: [
              const Expanded(child: AppSectionHeading('历史记录')),
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
          _compactEmpty(p, '暂无历史记录')
        else
          SizedBox(
            height: 172,
            child: AppHStrip.separated(
              controller: _continueScroll,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) =>
                  _unifiedHistoryCard(p, items[index]),
            ),
          ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _unifiedHistoryCard(AppPalette p, UnifiedHistoryItem item) {
    late final Widget cover;
    late final String progress;
    VoidCallback? onTap;
    switch (item.kind) {
      case UnifiedHistoryKind.manga:
        final history = item.manga!;
        final meta = _metaById(history.sourceId);
        final manga = Manga(
          id: history.mangaId,
          title: history.title,
          cover: history.cover,
        );
        cover = MangaCover(
          manga: manga,
          headers: meta == null ? const {} : imageHeadersOf(meta),
          radius: 8,
        );
        progress = history.lastChapterName;
        onTap = () => _openEntrySmart(
              title: history.title,
              sourceId: history.sourceId,
              mangaId: history.mangaId,
              cover: history.cover,
            );
      case UnifiedHistoryKind.novel:
        final entry = item.novelEntry!;
        final novel = Novel(
          id: entry.novelId ?? entry.fingerprint ?? entry.key,
          title: entry.title,
          cover: entry.cover,
          authors: entry.authors,
        );
        cover = NovelCover(novel: novel, radius: 8);
        progress = item.novelProgress!.locator.chapterId;
        if (entry.available) {
          onTap = () => openNovelLibraryEntry(context, entry);
        }
      case UnifiedHistoryKind.anime:
        final history = item.anime!;
        final meta = _metaById(history.sourceId);
        cover = MangaCover(
          manga: Manga(
            id: history.animeId,
            title: history.title,
            cover: history.cover,
          ),
          headers: meta == null ? const {} : imageHeadersOf(meta),
          radius: 8,
        );
        progress = '${history.episodeName} · '
            '${_formatClock(history.positionSeconds)}';
        onTap = () => openAnimeHistory(context, history);
    }
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(child: cover),
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
              style: TextStyle(
                fontSize: 10,
                height: 1.25,
                color: p.accentSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatClock(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final tail = '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
    return hours > 0 ? '$hours:$tail' : tail;
  }

  // 收藏网格。
  Widget _favoritesSection(
    AppPalette p,
    LibraryStore store, {
    List<({FavoriteEntry rep, int sources})>? favorites,
    EdgeInsets contentPadding = const EdgeInsets.fromLTRB(16, 0, 16, 4),
  }) {
    final favs = favorites ?? _dedupFavs(store); // 同名书跨源去重为一张卡(带「N源」角标)
    final layout = store.feedLayout;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(p, '漫画收藏'),
        if (favs.isEmpty)
          _compactEmpty(p, '暂无漫画收藏')
        else
          FeedView(
            layout: layout,
            shrinkWrap: true, // 嵌在书架外层 ListView 里,自身不滚
            columns: store.gridColumns,
            itemCount: favs.length,
            padding: contentPadding,
            cardBuilder: (context, i) => _favCard(p, favs[i], layout, 'fav'),
            tileBuilder: (context, i) => _favTile(p, favs[i], 'favl'),
          ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _novelFavoritesSection(
    AppPalette p,
    NovelLibraryStore store, {
    List<NovelLibraryEntry>? favorites,
    EdgeInsets contentPadding = const EdgeInsets.symmetric(horizontal: 16),
  }) {
    final entries = favorites ??
        (store.entries.where((entry) => entry.favorite).toList(growable: false)
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(p, '小说收藏'),
        if (entries.isEmpty)
          _compactEmpty(p, '暂无小说收藏')
        else
          SizedBox(
            height: 172,
            child: AppHStrip.separated(
              padding: contentPadding,
              itemCount: entries.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final novel = Novel(
                  id: entry.novelId ?? entry.fingerprint ?? entry.key,
                  title: entry.title,
                  cover: entry.cover,
                  authors: entry.authors,
                );
                return SizedBox(
                  width: 92,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: GestureDetector(
                          onTap: entry.available
                              ? () => openNovelLibraryEntry(context, entry)
                              : null,
                          child: NovelCover(
                            novel: novel,
                            radius: 8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _animeFavoritesSection(
    AppPalette p,
    AnimeLibraryStore store, {
    List<AnimeFavoriteEntry>? favorites,
    EdgeInsets contentPadding = const EdgeInsets.symmetric(horizontal: 16),
  }) {
    final entries = favorites ?? store.favorites;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(p, '番剧收藏'),
        if (entries.isEmpty)
          _compactEmpty(p, '暂无番剧收藏')
        else
          SizedBox(
            height: 172,
            child: AppHStrip.separated(
              padding: contentPadding,
              itemCount: entries.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final meta = _metaById(entry.sourceId);
                final anime = Manga(
                  id: entry.animeId,
                  title: entry.title,
                  cover: entry.cover,
                );
                return SizedBox(
                  width: 92,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: MangaCover(
                          manga: anime,
                          headers:
                              meta == null ? const {} : imageHeadersOf(meta),
                          radius: 8,
                          onTap: meta == null
                              ? null
                              : () => Navigator.of(context).push(appRoute(
                                    AnimeDetailPage(meta: meta, anime: anime),
                                  )),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _compactEmpty(AppPalette p, String message) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          message,
          style: TextStyle(color: p.textMuted, fontSize: 12.5),
        ),
      );

  // 收藏卡(瀑布流/网格):封面 + 标题。网格用 Flexible 防固定高单元格溢出;瀑布流取自然高。
  Widget _favCard(AppPalette p, ({FavoriteEntry rep, int sources}) item,
      FeedLayout layout, String tagPrefix) {
    final f = item.rep;
    final meta = _metaById(f.sourceId);
    final m = Manga(id: f.mangaId, title: f.title, cover: f.cover);
    final tag = meta != null ? '$tagPrefix:${meta.id}:${m.id}' : null;
    void open() => _openEntrySmart(
        title: f.title,
        sourceId: f.sourceId,
        mangaId: f.mangaId,
        cover: f.cover,
        heroTag: tag);
    final cover = MangaCover(
      manga: m,
      sourceCount: item.sources,
      headers: meta != null ? imageHeadersOf(meta) : const {},
      aspect: layout == FeedLayout.masonry ? aspectForId(m.id) : 3 / 4,
      heroTag: tag,
      onTap: open, // 源被删也能点:自动在其它源找同名打开
    );
    return _withEntryMenu(
      title: f.title,
      sourceId: f.sourceId,
      mangaId: f.mangaId,
      cover: f.cover,
      heroTag: tag,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          layout == FeedLayout.grid ? Flexible(child: cover) : cover,
          const SizedBox(height: 6),
          Text(f.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: p.textPrimary)),
        ],
      ),
    );
  }

  Widget _favTile(
      AppPalette p, ({FavoriteEntry rep, int sources}) item, String tagPrefix) {
    final f = item.rep;
    final meta = _metaById(f.sourceId);
    final m = Manga(id: f.mangaId, title: f.title, cover: f.cover);
    final tag = meta != null ? '$tagPrefix:${meta.id}:${m.id}' : null;
    return _withEntryMenu(
      title: f.title,
      sourceId: f.sourceId,
      mangaId: f.mangaId,
      cover: f.cover,
      heroTag: tag,
      child: coverListTile(p, context,
          manga: m,
          headers: meta != null ? imageHeadersOf(meta) : const {},
          sourceCount: item.sources,
          heroTag: tag,
          // 源被删也能点:自动在其它源找同名打开。
          onTap: () => _openEntrySmart(
              title: f.title,
              sourceId: f.sourceId,
              mangaId: f.mangaId,
              cover: f.cover,
              heroTag: tag)),
    );
  }

  Future<void> _pickSource(SourceMeta current) async {
    final id = await showSourcePicker(context, currentId: current.id);
    if (id == null) return;
    final picked = _metaById(id);
    if (picked != null) _sc!.current = picked;
  }

  Widget _sourcePicker(AppPalette p, SourceMeta meta, LibraryStore store) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: SourcePickerPill(
          label: context.l10n.shelf_sourceLatest(meta.name),
          onTap: () => _pickSource(meta),
        ),
      );

  Widget _browse(AppPalette p, LibraryStore store) {
    // 混合源:结果按到达顺序渐进出现;还没有任何结果时才转圈/报错。
    if (_feedItems.isEmpty) {
      if (_feedLoading) {
        return const SizedBox(
            height: 220, child: Center(child: CircularProgressIndicator()));
      }
      if (_feedError != null && _feedOk == 0) return _error(p, _feedError!);
      return _error(p, context.l10n.shelf_noDataEmpty);
    }
    // 跟随设置里的「封面布局」(瀑布流 / 网格 / 列表),与收藏区一致。
    final layout = store.feedLayout;
    return FeedView(
      layout: layout,
      shrinkWrap: true, // 嵌在书架外层 ListView 里,自身不滚
      columns: store.gridColumns,
      itemCount: _feedItems.length,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      cardBuilder: (context, i) => _browseCard(p, store, i, layout),
      tileBuilder: (context, i) => _browseTile(p, store, i),
    );
  }

  // 混合源 feed 里某本书的可用源数(驱动「N源」角标)。
  int _feedSrcCount(Manga m) {
    final k = ChineseFold.dedupKey(m.title);
    return k.isEmpty ? 1 : (_feedSrc[k]?.length ?? 1);
  }

  // 浏览卡(瀑布流/网格):封面 + 标题 + 作者。网格用 Flexible 防固定高溢出;瀑布流取自然高。
  Widget _browseCard(
      AppPalette p, LibraryStore store, int i, FeedLayout layout) {
    final item = _feedItems[i];
    final m = item.manga;
    // 带下标:源 feed 可能重复同一本,避免 Hero tag 撞车。
    final tag = 'feed:${item.meta.id}:${m.id}:$i';
    final cover = MangaCover(
      manga: m,
      headers: imageHeadersOf(item.meta),
      sourceCount: _feedSrcCount(m),
      updated: m.status == MangaStatus.ongoing,
      aspect: layout == FeedLayout.masonry ? aspectForId(m.id) : 3 / 4,
      heroTag: tag,
      onTap: () => _openManga(m, item.meta, heroTag: tag),
    );
    return FlyInUp(
      seed: m.id,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          layout == FeedLayout.grid ? Flexible(child: cover) : cover,
          const SizedBox(height: 6),
          Text(m.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: p.textPrimary)),
          Text(m.authors.isNotEmpty ? m.authors.first : ' ',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: p.textMuted)),
        ],
      ),
    );
  }

  // 浏览行(列表布局):横排封面 + 信息(复用书架列表行)。
  Widget _browseTile(AppPalette p, LibraryStore store, int i) {
    final item = _feedItems[i];
    final m = item.manga;
    final tag = 'feedl:${item.meta.id}:${m.id}:$i';
    return coverListTile(p, context,
        manga: m,
        headers: imageHeadersOf(item.meta),
        sourceCount: _feedSrcCount(m),
        heroTag: tag,
        onTap: () => _openManga(m, item.meta, heroTag: tag));
  }

  Widget _error(AppPalette p, String msg) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 40, color: p.textMuted),
              const SizedBox(height: 12),
              Text(context.l10n.loadFailed,
                  style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              SelectableText(msg,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textMuted, fontSize: 12)),
              const SizedBox(height: 14),
              FilledButton(
                  onPressed: _refresh, child: Text(context.l10n.retry)),
            ],
          ),
        ),
      );
}
