import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../app/library_store.dart';
import '../../app/source_controller.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/title_match.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import '../common/source_picker.dart';
import '../common/transitions.dart';
import '../detail/detail_page.dart';
import 'history_page.dart';
import 'manga_cover.dart';
import 'masonry_feed.dart';

/// 书架:置顶「继续阅读」+「收藏」(本地持久化),下面是**当前源**的最新更新;顶部可切换源。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  SourceController? _sc;
  late Future<List<Manga>> _future;
  final TextEditingController _shelfCtrl = TextEditingController();
  bool _showShelfSearch = false;
  String _shelfQuery = ''; // 非空 = 在收藏里筛选
  final ScrollController _continueScroll = ScrollController();

  @override
  void dispose() {
    _sc?.removeListener(_onSourceChanged);
    _shelfCtrl.dispose();
    _continueScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sc = SourceScope.of(context);
    if (sc != _sc) {
      _sc?.removeListener(_onSourceChanged);
      _sc = sc..addListener(_onSourceChanged);
      _future = _load();
    }
  }

  // 注意用块体:箭头体会让闭包“返回” _load() 的 Future,setState 会报错。
  void _onSourceChanged() => setState(() {
        _future = _load();
      });

  Future<List<Manga>> _load() async {
    final cur = _sc?.current;
    if (cur == null) return const []; // 未配置源:书架下半部走空态
    final source = buildSource(cur);
    try {
      final page = await source.getDiscovery(1);
      return page.items;
    } finally {
      source.dispose();
    }
  }

  void _refresh() => setState(() {
        _future = _load();
      });

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

  /// 继续阅读去重:同作品只留最近读的那条。
  List<({ReadState rep, int sources})> _dedupHistory(LibraryStore store) {
    final srcMap = _sourcesByWork(store);
    final seen = <String>{};
    final out = <({ReadState rep, int sources})>[];
    for (final h in store.history) {
      final core = coreTitle(h.title);
      final key = core.isEmpty ? 'raw:${h.key}' : _canonKey(core, srcMap.keys);
      if (!seen.add(key)) continue; // 保留第一条(history 已按最近排序)
      out.add((rep: h, sources: srcMap[key]?.length ?? 1));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = LibraryScope.of(context); // 依赖:收藏/进度变了自动重建
    final meta = _sc?.current; // 可能未配置源 → null
    // 内容延伸到毛玻璃标题栏之后 → 标题栏能糊到身后背景图;body 手动留出顶部内边距。
    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: const Text('书架',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          IconButton(
            tooltip: '在收藏里搜索',
            onPressed: () => setState(() {
              _showShelfSearch = !_showShelfSearch;
              if (!_showShelfSearch) {
                _shelfCtrl.clear();
                _shelfQuery = '';
              }
            }),
            icon: Icon(_showShelfSearch ? Icons.search_off_rounded : Icons.search_rounded),
          ),
          IconButton(
            tooltip: '阅读历史',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryPage())),
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
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
                    ? _shelfResults(p, store)
                    : AppScrollView(
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [
                          if (store.history.isNotEmpty) _continueStrip(p, store),
                          if (store.favorites.isNotEmpty)
                            _favoritesSection(p, store),
                          if (meta != null) ...[
                           _sectionHeader(p, "推荐"),
                            if (store.showSourcePicker)
                              _sourcePicker(p, meta, store),
                            _browse(p, meta, store),
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
            hintText: '在收藏里搜索…',
            hintStyle: TextStyle(color: p.textMuted, fontSize: 13),
            prefixIcon: Icon(Icons.search_rounded, size: 18, color: p.textMuted),
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

  Widget _shelfResults(AppPalette p, LibraryStore store) {
    final q = _shelfQuery.toLowerCase();
    final favs = _dedupFavs(store)
        .where((e) => e.rep.title.toLowerCase().contains(q))
        .toList();
    if (favs.isEmpty) {
      return EmptyState(title: '收藏里没有匹配「$_shelfQuery」的');
    }
    final layout = store.feedLayout;
    return FeedView(
      layout: layout,
      columns: store.gridColumns,
      itemCount: favs.length,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      cardBuilder: (context, i) => _favCard(p, favs[i], layout, 'search'),
      tileBuilder: (context, i) => _favTile(p, favs[i], 'searchl'),
    );
  }

  Widget _sectionHeader(AppPalette p, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 25),
        child: AppSectionHeading(text),
      );

  // 未配置漫画源(引擎不内置源,需在设置里添加源仓库)的空态。
  Widget _noSourceHint(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Column(
          children: [
            Icon(Icons.travel_explore_rounded, size: 44, color: p.textMuted),
            const SizedBox(height: 14),
            Text('还没有配置漫画源',
                style: TextStyle(
                    color: p.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
            const SizedBox(height: 8),
            Text('前往「设置 › 漫画源」填入源仓库地址或选择本地源目录后即可浏览。',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textMuted, fontSize: 13, height: 1.5)),
          ],
        ),
      );

  // 卡片进度文案:优先「作品级共享进度」的章(话数)—— 同名书跨源共用、各副本一致;
  // 无共享进度(话数解析不出)时退回本源页码/章名。
  String _progressText(LibraryStore store, ReadState h) {
    final wp = store.workProgressFor(h.title);
    if (wp != null && wp.chapterLabel.isNotEmpty) return '读到 ${wp.chapterLabel}';
    if (h.lastTotal > 0) return '读到 ${h.lastPage + 1}/${h.lastTotal}';
    return h.lastChapterName;
  }

  // 继续阅读:横向卡片条(同名书跨源去重为一张,带「N源」角标)。
  Widget _continueStrip(AppPalette p, LibraryStore store) {
    final items = _dedupHistory(store).take(12).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(p, '继续阅读'),
        SizedBox(
          height: 172,
          // 桌面:竖向滚轮转横向滚动 + 允许鼠标拖拽,否则溢出屏外的卡片够不着。
          child: Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && _continueScroll.hasClients) {
                final d = e.scrollDelta.dy != 0 ? e.scrollDelta.dy : e.scrollDelta.dx;
                final t = (_continueScroll.offset + d)
                    .clamp(0.0, _continueScroll.position.maxScrollExtent);
                _continueScroll.jumpTo(t);
              }
            },
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                },
                scrollbars: false,
              ),
              child: AppScrollView.separated(
            controller: _continueScroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final h = items[i].rep;
              final meta = _metaById(h.sourceId);
              final m = Manga(id: h.mangaId, title: h.title, cover: h.cover);
              final tag = meta != null ? 'cont:${meta.id}:${m.id}' : null;
              return SizedBox(
                width: 92,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 封面用 Flexible 包住:文字取自然高度后,封面自适应剩余高度
                    // (最多缩一两像素),无论字体行高多大都不会撑破固定高卡片。
                    Flexible(
                      child: MangaCover(
                        manga: m,
                        sourceCount: items[i].sources,
                        headers: meta != null ? imageHeadersOf(meta) : const {},
                        heroTag: tag,
                        onTap: meta != null
                            ? () => _openManga(m, meta, heroTag: tag)
                            : null,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // CJK 回退字体默认行高很高(~1.5),两行标题+进度会撑破固定
                    // 高的横排卡片;显式 height 收紧行高,配合上面的 Flexible 兜底。
                    Text(h.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5,
                            height: 1.25,
                            fontWeight: FontWeight.w700,
                            color: p.textPrimary)),
                    Text(
                      _progressText(store, h),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 10, height: 1.25, color: p.accentSoft),
                    ),
                  ],
                ),
              );
            },
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  // 收藏网格。
  Widget _favoritesSection(AppPalette p, LibraryStore store) {
    final favs = _dedupFavs(store); // 同名书跨源去重为一张卡(带「N源」角标)
    final layout = store.feedLayout;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(p, '收藏 · ${favs.length}'),
        FeedView(
          layout: layout,
          shrinkWrap: true, // 嵌在书架外层 ListView 里,自身不滚
          columns: store.gridColumns,
          itemCount: favs.length,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          cardBuilder: (context, i) => _favCard(p, favs[i], layout, 'fav'),
          tileBuilder: (context, i) => _favTile(p, favs[i], 'favl'),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  // 收藏卡(瀑布流/网格):封面 + 标题。网格用 Flexible 防固定高单元格溢出;瀑布流取自然高。
  Widget _favCard(AppPalette p, ({FavoriteEntry rep, int sources}) item,
      FeedLayout layout, String tagPrefix) {
    final f = item.rep;
    final meta = _metaById(f.sourceId);
    final m = Manga(id: f.mangaId, title: f.title, cover: f.cover);
    final tag = meta != null ? '$tagPrefix:${meta.id}:${m.id}' : null;
    final cover = MangaCover(
      manga: m,
      sourceCount: item.sources,
      headers: meta != null ? imageHeadersOf(meta) : const {},
      aspect: layout == FeedLayout.masonry ? aspectForId(m.id) : 3 / 4,
      heroTag: tag,
      onTap: meta != null ? () => _openManga(m, meta, heroTag: tag) : null,
    );
    return Column(
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
    );
  }

  Widget _favTile(AppPalette p, ({FavoriteEntry rep, int sources}) item,
      String tagPrefix) {
    final f = item.rep;
    final meta = _metaById(f.sourceId);
    final m = Manga(id: f.mangaId, title: f.title, cover: f.cover);
    final tag = meta != null ? '$tagPrefix:${meta.id}:${m.id}' : null;
    return coverListTile(p, context,
        manga: m,
        headers: meta != null ? imageHeadersOf(meta) : const {},
        sourceCount: item.sources,
        heroTag: tag,
        onTap: meta != null ? () => _openManga(m, meta, heroTag: tag) : () {});
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
          label: '${meta.name} · 最新更新',
          onTap: () => _pickSource(meta),
        ),
      );

  Widget _browse(AppPalette p, SourceMeta meta, LibraryStore store) =>
      FutureBuilder<List<Manga>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const SizedBox(
                height: 220, child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) return _error(p, '${snap.error}');
          final items = snap.data ?? const [];
          if (items.isEmpty) return _error(p, '没有拿到数据(列表为空)');
          // 瀑布流:嵌在外层 ListView 里,shrinkWrap + 禁自身滚动。
          return LayoutBuilder(
            builder: (context, c) => MasonryGridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
              crossAxisCount: columnsFor(c.maxWidth, store.gridColumns),
              crossAxisSpacing: 12,
              mainAxisSpacing: 14,
              itemCount: items.length,
              itemBuilder: (context, i) {
                final m = items[i];
                // 带下标:源 feed 分页可能重复同一本,避免 Hero tag 撞车。
                final tag = 'feed:${meta.id}:${m.id}:$i';
                return FlyInUp(
                  seed: m.id,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 瀑布流 tile 高度由内容决定(无界主轴)→ 不能用 Flexible。
                      // MangaCover 自带 AspectRatio,直接放,高度自然算出。
                      MangaCover(
                        manga: m,
                        headers: imageHeadersOf(meta),
                        updated: m.status == MangaStatus.ongoing,
                        aspect: aspectForId(m.id),
                        heroTag: tag,
                        onTap: () => _openManga(m, meta, heroTag: tag),
                      ),
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
              },
            ),
          );
        },
      );

  Widget _error(AppPalette p, String msg) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 40, color: p.textMuted),
              const SizedBox(height: 12),
              Text('加载失败',
                  style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              SelectableText(msg,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textMuted, fontSize: 12)),
              const SizedBox(height: 14),
              FilledButton(onPressed: _refresh, child: const Text('重试')),
            ],
          ),
        ),
      );
}
