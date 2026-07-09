import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/content_kind.dart';
import '../../app/library_store.dart';
import '../../app/source_controller.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/title_match.dart';
import '../../core/translate/translator.dart';
import '../../ui/ui.dart';
import '../anime/anime_browser.dart';
import '../common/animations.dart';
import '../common/source_picker.dart';
import '../common/transitions.dart';
import '../detail/detail_page.dart';
import 'browse_page.dart';
import '../library/manga_cover.dart';
import '../library/masonry_feed.dart';

/// 混合模式下每个结果记住自己的源(卡片角标 + 打开详情用)。
typedef _Result = ({Manga manga, SourceMeta meta});

/// 混合模式:每个源一份独立游标 —— 各自异步翻页、先到先显示,慢源不拖累快源。
class _MixedCursor {
  _MixedCursor(this.meta, this.source);
  final SourceMeta meta;
  final MangaSource source;
  int page = 1;
  bool hasNext = true;
  bool loading = false;
}

/// 「混合(全部源)」占位源。
const _mixedMetaId = '__all__';
const _mixedMeta = SourceMeta(id: _mixedMetaId, name: '混合 · 全部源', script: '');

/// 发现:按当前源的筛选维度(地区/剧情/受众/进度/排序)浏览,分页无限加载。
/// 源未声明筛选时,退化为纯分页浏览。**混合模式**:并发查全部启用源、合并结果。
class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({super.key});

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  ContentKind _kind = ContentKind.manga; // 内容类型:番剧/小说为预留占位
  SourceController? _sc;
  SourceMeta? _meta;
  MangaSource? _source;
  List<FilterDef> _filters = const [];
  final Map<String, String> _selected = {};
  final ScrollController _scroll = ScrollController();

  bool _mixed = false; // 混合模式:并发查全部启用源
  final List<_MixedCursor> _mixedSources = [];
  // 混合模式的通用筛选(翻译到各源的原生筛选,见 _mixedFiltersFor)。
  String _mixedSort = 'latest'; // latest | popular
  String _mixedStatus = ''; // '' | ongoing | completed

  // 混合去重:归一化标题 → 该书在 _results 中的下标 / 已贡献它的源 id 集合。
  // 同名只显示一次(保留最先到达的源为代表),其余源只累加到源集合 → 「N源」角标。
  final Map<String, int> _titlePos = {};
  final Map<String, Set<String>> _titleSrcIds = {};
  // 加载会话代际:每次 _reset 自增。单源与混合的在途旧请求回来后都据此丢弃
  // (切筛选/搜索/换源期间旧的 getSearch/getDiscovery 完成时不再 append,避免污染新结果、
  // 跳页、以及切到无源态后 _meta! 空断言崩溃)。
  int _loadGen = 0;

  final List<_Result> _results = [];
  int _page = 1;
  bool _loading = false;
  bool _hasNext = true;
  String? _error;
  bool _showFilters = true;

  final TextEditingController _searchCtrl = TextEditingController();
  bool _showSearch = false;
  String _query = ''; // 非空 = 搜索模式
  bool _translating = false; // 正在翻译搜索词

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sc = SourceScope.of(context);
    final scChanged = sc != _sc;
    if (scChanged) {
      _sc?.removeListener(_onSourceChanged);
      _sc = sc..addListener(_onSourceChanged);
    }
    // 关掉「显示源选择器」→ 强制混合源;开着则保持当前(用户可切)。
    // 设置在运行时切换也在这里生效(本页依赖 LibraryScope,notify 会触发本回调)。
    final wantMixed = LibraryScope.of(context).showSourcePicker ? _mixed : true;
    if (scChanged || wantMixed != _mixed) {
      _mixed = wantMixed;
      _rebuildSource();
    }
  }

  void _onSourceChanged() {
    if (_mixed) return; // 混合模式下忽略全局单源切换
    _rebuildSource();
  }

  void _disposeSources() {
    _source?.dispose();
    _source = null;
    for (final ms in _mixedSources) {
      ms.source.dispose();
    }
    _mixedSources.clear();
  }

  void _rebuildSource() {
    _disposeSources();
    _filters = const [];
    _selected.clear();
    if (_mixed) {
      // 混合:构建全部启用源,发现/搜索时并发查、合并。混合模式不显示单源筛选。
      _meta = _mixedMeta;
      final store = LibraryScope.read(context);
      for (final s in registeredSources) {
        if (store.isSourceEnabled(s.id)) {
          _mixedSources.add(_MixedCursor(s, buildSource(s)));
        }
      }
      _reset();
      return;
    }
    final cur = _sc?.current;
    if (cur == null) {
      // 未配置源:不建源,_loadMore 会因 _source==null 早退,页面走空态。
      _meta = null;
      _source = null;
      _filters = const [];
      _reset();
      return;
    }
    _meta = cur;
    _source = buildSource(cur);
    _filters = _source!.filters;
    for (final f in _filters) {
      if (f.type == 'sort' && f.options.isNotEmpty) {
        _selected[f.id] = f.options.first.value; // 排序默认第一项
      }
    }
    _reset();
  }

  void _reset() {
    // 作废在途请求(单源+混合共用代际),复位每源游标与去重表。
    _loadGen++;
    for (final c in _mixedSources) {
      c.page = 1;
      c.hasNext = true;
      c.loading = false;
    }
    _titlePos.clear();
    _titleSrcIds.clear();
    setState(() {
      _results.clear();
      _page = 1;
      _hasNext = true;
      _error = null;
      _loading = false;
    });
    _loadMore();
  }

  Map<String, Object?> _activeFilters() => {
        for (final e in _selected.entries)
          if (e.value.isNotEmpty) e.key: e.value,
      };

  void _search(String q) {
    q = q.trim();
    if (q.isNotEmpty) LibraryScope.read(context).addSearchHistory(q);
    if (q == _query) return;
    _query = q;
    _reset();
  }

  Future<void> _loadMore() async {
    if (_mixed) {
      // 混合:各源独立判断/翻页(不受全局 _loading 门限),快源立即出结果。
      if (_mixedSources.isEmpty) return;
      for (final c in _mixedSources) {
        unawaited(_pumpCursor(c));
      }
      return;
    }
    if (_loading || !_hasNext) return;
    if (_source == null) return;
    final gen = _loadGen; // 期间若 _reset(切筛选/搜索/换源)则本次结果作废
    final meta = _meta;
    setState(() => _loading = true);
    try {
      final page = _query.isNotEmpty
          ? await _source!.getSearch(_query, _page)
          : await _source!.getDiscovery(_page, filters: _activeFilters());
      if (!mounted || gen != _loadGen) return; // 已被新一轮取代:丢弃陈旧结果
      setState(() {
        _results.addAll(page.items.map((m) => (manga: m, meta: meta!)));
        _hasNext = page.hasNext && page.items.isNotEmpty;
        _page++;
        _loading = false;
      });
    } catch (e) {
      if (mounted && gen == _loadGen) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// 混合:拉某个源的下一页并**就地追加**(异步、独立)。慢源不阻塞其它源;
  /// 单源报错(限流等)只停掉该源,不影响别的源;结果按到达顺序落盘,同名去重。
  Future<void> _pumpCursor(_MixedCursor c) async {
    if (c.loading || !c.hasNext) return;
    final gen = _loadGen;
    final page = c.page;
    final q = _query;
    c.loading = true;
    if (mounted) setState(_recomputeMixedFlags);
    try {
      final r = q.isNotEmpty
          ? await c.source.getSearch(q, page)
          : await c.source.getDiscovery(page, filters: _mixedFiltersFor(c.source));
      if (!mounted || gen != _loadGen) return; // 已 reset:丢弃这批陈旧结果
      _ingestMixed(c.meta, r.items);
      c.page++;
      c.hasNext = r.hasNext && r.items.isNotEmpty;
    } catch (_) {
      if (gen == _loadGen) c.hasNext = false; // 某源失败:停掉它
    } finally {
      if (gen == _loadGen) {
        c.loading = false;
        if (mounted) setState(_recomputeMixedFlags);
      }
    }
  }

  /// 把一批结果按「归一化标题」去重后并入 _results:新标题追加成卡片(记源为代表),
  /// 已存在的标题只把源 id 累加到集合(驱动「N源」角标),不再重复出卡。
  void _ingestMixed(SourceMeta meta, List<Manga> items) {
    for (final m in items) {
      final key = normalizeTitle(m.title);
      if (key.isEmpty) {
        _results.add((manga: m, meta: meta)); // 无法归一(纯符号名)→ 不去重
        continue;
      }
      final pos = _titlePos[key];
      if (pos == null) {
        _titlePos[key] = _results.length;
        _titleSrcIds[key] = {meta.id};
        _results.add((manga: m, meta: meta));
      } else {
        (_titleSrcIds[key] ??= {}).add(meta.id);
      }
    }
  }

  // 混合总体标志:任一源在加载 = 转圈;任一源还有下一页 = 可继续翻。
  void _recomputeMixedFlags() {
    _loading = _mixedSources.any((c) => c.loading);
    _hasNext = _mixedSources.any((c) => c.hasNext);
  }

  void _onScroll() {
    if (_scroll.position.pixels >
        _scroll.position.maxScrollExtent - 700) {
      _loadMore();
    }
  }

  void _pick(String id, String value) {
    if (_selected[id] == value) return;
    _selected[id] = value;
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = LibraryScope.of(context);
    final columns = store.gridColumns;
    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: const Text('发现',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          if (_kind == ContentKind.manga) ...[
          IconButton(
            tooltip: '搜索',
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch && _query.isNotEmpty) {
                _searchCtrl.clear();
                _search('');
              }
            }),
            icon: Icon(_showSearch ? Icons.search_off_rounded : Icons.search_rounded),
          ),
          // 站点板块浏览(排行榜/连载/完结…):仅当前源声明了 sections 时显示。
          if (!_mixed && _meta != null && (_source?.sections.isNotEmpty ?? false))
            IconButton(
              tooltip: '浏览板块',
              onPressed: () => Navigator.of(context)
                  .push(appRoute(BrowsePage(meta: _meta!))),
              icon: const Icon(Icons.dashboard_rounded),
            ),
          if (_filters.isNotEmpty || _mixed)
            IconButton(
              tooltip: _showFilters ? '收起筛选' : '展开筛选',
              onPressed: () => setState(() => _showFilters = !_showFilters),
              icon: Icon(_showFilters
                  ? Icons.filter_list_rounded
                  : Icons.filter_list_off_rounded),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: EntranceSlide(
        begin: const Offset(0, 0.06),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: Column(
        children: [
          _kindSwitcher(p),
          if (_kind == ContentKind.manga) ...[
            // 源选择器默认隐藏(直接用混合源);设置里打开才显示。
            if (store.showSourcePicker) _sourcePicker(p, store),
            // 搜索框 / 筛选条:用 AnimatedSize 展开收起,避免整页内容硬跳。
            _animExpand(_showSearch
                ? _searchField(p)
                : const SizedBox(width: double.infinity)),
            // 搜索历史:仅在搜索框展开且未在搜索时显示,点击回填并重搜。
            _animExpand((_showSearch && _query.isEmpty && store.searchHistory.isNotEmpty)
                ? _recentSearches(p, store)
                : const SizedBox(width: double.infinity)),
            _animExpand(
              (_mixed && _showFilters && _query.isEmpty)
                  ? _mixedFilterBar(p)
                  : (_filters.isNotEmpty && _showFilters && _query.isEmpty)
                      ? _filterBar(p)
                      : const SizedBox(width: double.infinity),
            ),
            Expanded(child: _grid(p, store, columns)),
          ] else if (_kind == ContentKind.anime)
            const Expanded(child: AnimeBrowser())
          else
            Expanded(child: _comingSoon(p, _kind)),
        ],
          ),
        ),
      ),
    );
  }

  // 内容类型切换:漫画(现用)/ 番剧 / 小说(预留占位)。
  Widget _kindSwitcher(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
        child: Row(
          children: [
            for (final k in ContentKind.values) ...[
              _kindChip(p, k),
              const SizedBox(width: 8),
            ],
          ],
        ),
      );

  Widget _kindChip(AppPalette p, ContentKind k) {
    final sel = _kind == k;
    return GestureDetector(
      onTap: () => setState(() => _kind = k),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
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
            Icon(k.icon, size: 15, color: sel ? p.accent : p.textMuted),
            const SizedBox(width: 5),
            Text(k.label,
                style: TextStyle(
                    color: sel ? p.accent : p.textPrimary,
                    fontSize: 12.5,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _comingSoon(AppPalette p, ContentKind kind) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(kind.icon, size: 56, color: p.textMuted),
            const SizedBox(height: 16),
            Text('${kind.label} · 即将推出',
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('这个板块正在规划中,后续版本接入',
                style: TextStyle(color: p.textMuted, fontSize: 13)),
          ],
        ),
      );

  // 源选择器:切换全局当前源,发现页据此重载筛选/列表(与书架共用同一当前源)。
  Future<void> _pickSource() async {
    final id = await showSourcePicker(
      context,
      currentId: _mixed ? _mixedMetaId : (_meta?.id ?? ''),
      includeMixed: true,
      mixedId: _mixedMetaId,
    );
    if (id == null || !mounted) return;
    if (id == _mixedMetaId) {
      if (_mixed) return;
      setState(() => _mixed = true);
      _rebuildSource();
      return;
    }
    SourceMeta? picked;
    for (final s in registeredSources) {
      if (s.id == id) {
        picked = s;
        break;
      }
    }
    if (picked == null) return;
    final wasMixed = _mixed;
    _mixed = false;
    if (wasMixed && _sc?.current?.id == picked.id) {
      _rebuildSource(); // 混合切回同一个当前源:setter 不 notify,手动重建
    } else {
      _sc?.current = picked; // → _onSourceChanged → _rebuildSource
    }
  }

  Widget _sourcePicker(AppPalette p, LibraryStore store) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: SourcePickerPill(
          icon: _mixed ? Icons.dashboard_rounded : Icons.source_rounded,
          label: _mixed
              ? '混合 · 全部源'
              : '${_meta?.name ?? '选择源'} · 分类浏览',
          onTap: _pickSource,
        ),
      );

  Widget _searchField(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Row(
          children: [
            Expanded(child: _searchInput(p)),
            const SizedBox(width: 6),
            _translateButton(p),
          ],
        ),
      );

  Widget _searchInput(AppPalette p) => TextField(
          controller: _searchCtrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          style: TextStyle(color: p.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索漫画名 · ${_meta?.name ?? ''}',
            hintStyle: TextStyle(color: p.textMuted, fontSize: 13),
            prefixIcon: Icon(Icons.search_rounded, size: 18, color: p.textMuted),
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear_rounded, size: 18, color: p.textMuted),
                    onPressed: () {
                      _searchCtrl.clear();
                      _search('');
                    },
                  )
                : null,
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
        );

  // 搜索词翻译按钮:点开选目标语言(简/繁/EN),翻好后回填并重搜。
  Widget _translateButton(AppPalette p) {
    if (_translating) {
      return const SizedBox(
        width: 44,
        height: 44,
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: PopupMenuButton<TranslateLang>(
        tooltip: '翻译搜索词',
        icon: Icon(Icons.translate_rounded, size: 20, color: p.accent),
        onSelected: _translateQuery,
        itemBuilder: (_) => [
          for (final l in TranslateLang.values)
            PopupMenuItem(value: l, child: Text('译为 ${l.label}')),
        ],
      ),
    );
  }

  Future<void> _translateQuery(TranslateLang target) async {
    final text = _searchCtrl.text.trim();
    if (text.isEmpty || _translating) return;
    final store = LibraryScope.read(context);
    setState(() => _translating = true);
    try {
      final tr =
          Translator.create(store.translateProvider, llm: store.translateLlm);
      final out = await tr.translate(text, target);
      if (!mounted) return;
      _searchCtrl.text = out;
      _searchCtrl.selection = TextSelection.collapsed(offset: out.length);
      _search(out); // 翻好即用译文搜(方便换语种源)
    } catch (e) {
      if (mounted) showAppNotify(context, '$e', kind: AppNotifyKind.error);
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  // 搜索历史面板:标题 + 清空 + 可横向换行的历史词条(词条自带 × 单删)。
  Widget _recentSearches(AppPalette p, LibraryStore store) {
    final items = store.searchHistory;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history_rounded, size: 14, color: p.textMuted),
              const SizedBox(width: 6),
              Text('最近搜索',
                  style: TextStyle(
                      color: p.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              Pressable(
                onTap: store.clearSearchHistory,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text('清空',
                      style: TextStyle(color: p.textMuted, fontSize: 12)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final q in items) _historyChip(p, store, q)],
          ),
        ],
      ),
    );
  }

  Widget _historyChip(AppPalette p, LibraryStore store, String q) => Pressable(
        onTap: () {
          _searchCtrl.text = q;
          _searchCtrl.selection = TextSelection.collapsed(offset: q.length);
          _search(q);
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 5, 5, 5),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(context.radius * 0.7),
            border: Border.all(color: p.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(q,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.textPrimary, fontSize: 12.5)),
              ),
              const SizedBox(width: 3),
              // 单删按钮:独立点区,不触发整条重搜。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => store.removeSearchHistory(q),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.close_rounded, size: 13, color: p.textMuted),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _filterBar(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _filters.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _filterRow(p, _filters[i]),
            ],
          ],
        ),
      );

  Widget _filterRow(AppPalette p, FilterDef f) => _filterCard(
        p,
        _filterIcon(f),
        f.label,
        [
          for (final o in f.options)
            _chip(p, o.label, (_selected[f.id] ?? '') == o.value,
                () => _pick(f.id, o.value)),
        ],
      );

  // 单个筛选维度 = 一张描边卡(参照设置页 UI 库风格):图标 + 维度名 + 横滑 chips。
  Widget _filterCard(
          AppPalette p, IconData icon, String label, List<Widget> chips) =>
      AppCard(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: p.accent),
            const SizedBox(width: 8),
            SizedBox(
              // 固定宽保证各行 chips 左缘对齐;52 容得下 4 个中文维度名,更长才省略。
              width: 52,
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 6),
            Expanded(
              // 关掉桌面横向滚动条(与书架/阅读器横滑条一致),免得压在矮卡片里的 chips 上。
              child: ScrollConfiguration(
                behavior:
                    ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: chips),
                ),
              ),
            ),
          ],
        ),
      );

  // 按维度名/类型猜一个贴切的前导图标;源自定义维度也有兜底(tune)。
  IconData _filterIcon(FilterDef f) {
    if (f.type == 'sort') return Icons.sort_rounded;
    final l = f.label;
    if (l.contains('地区') ||
        l.contains('地域') ||
        l.contains('区域') ||
        l.contains('国')) {
      return Icons.public_rounded;
    }
    if (l.contains('受众') ||
        l.contains('读者') ||
        l.contains('性别') ||
        l.contains('对象')) {
      return Icons.groups_rounded;
    }
    if (l.contains('进度') ||
        l.contains('状态') ||
        l.contains('连载') ||
        l.contains('連載')) {
      return Icons.timelapse_rounded;
    }
    if (l.contains('排序') || l.contains('sort')) return Icons.sort_rounded;
    if (l.contains('剧情') ||
        l.contains('题材') ||
        l.contains('类型') ||
        l.contains('類型') ||
        l.contains('分类') ||
        l.contains('genre')) {
      return Icons.local_offer_rounded;
    }
    return Icons.tune_rounded;
  }

  // 展开/收起用的高度动画包装(关动画时零时长=瞬时)。
  Widget _animExpand(Widget child) => AnimatedSize(
        duration: LibraryStore.animationsEnabled
            ? const Duration(milliseconds: 220)
            : Duration.zero,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: child,
      );

  Widget _chip(AppPalette p, String label, bool active, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Pressable(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: active ? p.accent.withValues(alpha: 0.16) : p.surface,
              borderRadius: BorderRadius.circular(context.radius * 0.6),
              border: Border.all(
                  color: active ? p.accent : p.line, width: active ? 1.2 : 1),
            ),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 160),
              style: TextStyle(
                  color: active ? p.accent : p.textMuted,
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500),
              child: Text(label),
            ),
          ),
        ),
      );

  /// 把混合模式的通用筛选(排序/进度)翻译成某个源的原生筛选,靠 FilterDef 标签语义匹配。
  /// 源没有对应维度就忽略(那个源用默认浏览)。
  Map<String, Object?> _mixedFiltersFor(MangaSource src) {
    final out = <String, Object?>{};
    for (final f in src.filters) {
      if (f.type == 'sort') {
        for (final o in f.options) {
          final l = o.label.toLowerCase();
          final isPop = o.label.contains('人气') ||
              o.label.contains('热') ||
              l.contains('pop');
          final isNew = o.label.contains('更新') ||
              o.label.contains('最新') ||
              l.contains('latest') ||
              l.contains('updat');
          if (_mixedSort == 'popular' && isPop) {
            out[f.id] = o.value;
            break;
          }
          if (_mixedSort == 'latest' && isNew) {
            out[f.id] = o.value;
            break;
          }
        }
      } else if (_mixedStatus.isNotEmpty) {
        final hasStatus = f.options.any((o) =>
            o.label.contains('连载') ||
            o.label.contains('連載') ||
            o.label.contains('完结') ||
            o.label.contains('完結'));
        if (hasStatus) {
          for (final o in f.options) {
            final ongoing = o.label.contains('连载') || o.label.contains('連載');
            final done = o.label.contains('完结') || o.label.contains('完結');
            if (_mixedStatus == 'ongoing' && ongoing) {
              out[f.id] = o.value;
              break;
            }
            if (_mixedStatus == 'completed' && done) {
              out[f.id] = o.value;
              break;
            }
          }
        }
      }
    }
    return out;
  }

  // 混合模式的通用筛选栏(排序 + 进度),各源尽力翻译。
  Widget _mixedFilterBar(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _mixedRow(p, Icons.sort_rounded, '排序', const [
              ('latest', '最新更新'),
              ('popular', '人气'),
            ], _mixedSort, (v) {
              _mixedSort = v;
              _reset();
            }),
            const SizedBox(height: 8),
            _mixedRow(p, Icons.timelapse_rounded, '进度', const [
              ('', '全部'),
              ('ongoing', '连载中'),
              ('completed', '已完结'),
            ], _mixedStatus, (v) {
              _mixedStatus = v;
              _reset();
            }),
          ],
        ),
      );

  Widget _mixedRow(AppPalette p, IconData icon, String label,
          List<(String, String)> opts, String cur,
          void Function(String) onPick) =>
      _filterCard(
        p,
        icon,
        label,
        [
          for (final o in opts) _chip(p, o.$2, cur == o.$1, () => onPick(o.$1)),
        ],
      );

  Widget _grid(AppPalette p, LibraryStore store, int columns) {
    if (_results.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      if (_error != null) return _errorView(p);
      return Center(
        child: Text('没有拿到数据',
            style: TextStyle(color: p.textMuted, fontSize: 13)),
      );
    }
    final layout = store.feedLayout;
    // 混合去重后,这本书被几个源命中(≥2 时显示「N源」角标)。
    int srcCountOf(Manga m) =>
        _mixed ? (_titleSrcIds[normalizeTitle(m.title)]?.length ?? 1) : 1;
    void open(Manga m, SourceMeta meta, String tag) => Navigator.of(context)
        .push(appRoute(DetailPage(manga: m, meta: meta, heroTag: tag)));

    return FeedView(
      layout: layout,
      controller: _scroll,
      columns: columns,
      itemCount: _results.length,
      footer: _footer(p),
      cardBuilder: (context, i) {
        final m = _results[i].manga;
        final meta = _results[i].meta;
        // 带下标:搜索/发现结果可能重复同一本,避免 Hero tag 撞车。
        final tag = 'disc:${meta.id}:${m.id}:$i';
        final cover = MangaCover(
          manga: m,
          headers: imageHeadersOf(meta),
          sourceCount: srcCountOf(m),
          // 瀑布流:高低错落;网格:统一 3:4。
          aspect: layout == FeedLayout.masonry ? aspectForId(m.id) : 3 / 4,
          heroTag: tag,
          onTap: () => open(m, meta, tag),
        );
        return FlyInUp(
          seed: m.id, // 稳定:同一张卡飞入距离/延迟不变,翻页不跳
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 网格是固定高单元格 → Flexible 防溢出;瀑布流取自然高。
              layout == FeedLayout.grid ? Flexible(child: cover) : cover,
              const SizedBox(height: 6),
              Text(m.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: p.textPrimary)),
            ],
          ),
        );
      },
      tileBuilder: (context, i) {
        final m = _results[i].manga;
        final meta = _results[i].meta;
        final tag = 'disc:${meta.id}:${m.id}:$i';
        return FlyInUp(
          seed: m.id,
          child: coverListTile(p, context,
              manga: m,
              headers: imageHeadersOf(meta),
              sourceCount: srcCountOf(m),
              heroTag: tag,
              onTap: () => open(m, meta, tag)),
        );
      },
    );
  }

  Widget _footer(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        child: Center(
          child: _loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4))
              : _error != null
                  ? TextButton(
                      onPressed: _loadMore, child: const Text('加载失败,重试'))
                  : !_hasNext
                      ? Text('没有更多了',
                          style: TextStyle(color: p.textMuted, fontSize: 11))
                      : const SizedBox.shrink(),
        ),
      );

  Widget _errorView(AppPalette p) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 40, color: p.textMuted),
              const SizedBox(height: 12),
              SelectableText('加载失败:\n$_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textMuted, fontSize: 12)),
              const SizedBox(height: 14),
              FilledButton(onPressed: _reset, child: const Text('重试')),
            ],
          ),
        ),
      );

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    _sc?.removeListener(_onSourceChanged);
    _disposeSources();
    super.dispose();
  }
}
