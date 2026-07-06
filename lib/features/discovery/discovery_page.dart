import 'package:flutter/material.dart';

import '../../app/content_kind.dart';
import '../../app/library_store.dart';
import '../../app/source_controller.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../common/animations.dart';
import '../common/source_picker.dart';
import '../common/transitions.dart';
import '../detail/detail_page.dart';
import 'browse_page.dart';
import '../library/manga_cover.dart';
import '../library/masonry_feed.dart';

/// 混合模式下每个结果记住自己的源(卡片角标 + 打开详情用)。
typedef _Result = ({Manga manga, SourceMeta meta});

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
  final List<({SourceMeta meta, MangaSource source})> _mixedSources = [];
  // 混合模式的通用筛选(翻译到各源的原生筛选,见 _mixedFiltersFor)。
  String _mixedSort = 'latest'; // latest | popular
  String _mixedStatus = ''; // '' | ongoing | completed

  final List<_Result> _results = [];
  int _page = 1;
  bool _loading = false;
  bool _hasNext = true;
  String? _error;
  bool _showFilters = true;

  final TextEditingController _searchCtrl = TextEditingController();
  bool _showSearch = false;
  String _query = ''; // 非空 = 搜索模式

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sc = SourceScope.of(context);
    if (sc != _sc) {
      _sc?.removeListener(_onSourceChanged);
      _sc = sc..addListener(_onSourceChanged);
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
          _mixedSources.add((meta: s, source: buildSource(s)));
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
    setState(() {
      _results.clear();
      _page = 1;
      _hasNext = true;
      _error = null;
    });
    _loadMore();
  }

  Map<String, Object?> _activeFilters() => {
        for (final e in _selected.entries)
          if (e.value.isNotEmpty) e.key: e.value,
      };

  void _search(String q) {
    q = q.trim();
    if (q == _query) return;
    _query = q;
    _reset();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasNext) return;
    if (_mixed ? _mixedSources.isEmpty : _source == null) return;
    setState(() => _loading = true);
    try {
      if (_mixed) {
        await _loadMoreMixed();
        return;
      }
      final page = _query.isNotEmpty
          ? await _source!.getSearch(_query, _page)
          : await _source!.getDiscovery(_page, filters: _activeFilters());
      if (!mounted) return;
      setState(() {
        _results.addAll(page.items.map((m) => (manga: m, meta: _meta!)));
        _hasNext = page.hasNext && page.items.isNotEmpty;
        _page++;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// 混合:并发查每个启用源的第 [_page] 页,轮转交错合并(各源结果交替出现)。
  /// 单源报错(限流等)不影响其它源;全部为空才停止翻页。
  Future<void> _loadMoreMixed() async {
    final page = _page;
    final q = _query;
    final lists = await Future.wait(_mixedSources.map((ms) async {
      try {
        final r = q.isNotEmpty
            ? await ms.source.getSearch(q, page)
            : await ms.source.getDiscovery(page,
                filters: _mixedFiltersFor(ms.source));
        return r.items.map<_Result>((m) => (manga: m, meta: ms.meta)).toList();
      } catch (_) {
        return <_Result>[]; // 某源失败就跳过它
      }
    }));
    if (!mounted) return;
    // 轮转交错:第 i 轮从每个源各取一个,避免某个源霸屏。
    final merged = <_Result>[];
    var more = true;
    for (var i = 0; more; i++) {
      more = false;
      for (final l in lists) {
        if (i < l.length) {
          merged.add(l[i]);
          more = true;
        }
      }
    }
    setState(() {
      _results.addAll(merged);
      _hasNext = merged.isNotEmpty;
      _page++;
      _loading = false;
    });
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
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
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
      body: Column(
        children: [
          _kindSwitcher(p),
          if (_kind == ContentKind.manga) ...[
            _sourcePicker(p, store),
            // 搜索框 / 筛选条:用 AnimatedSize 展开收起,避免整页内容硬跳。
            _animExpand(_showSearch
                ? _searchField(p)
                : const SizedBox(width: double.infinity)),
            _animExpand(
              (_mixed && _showFilters && _query.isEmpty)
                  ? _mixedFilterBar(p)
                  : (_filters.isNotEmpty && _showFilters && _query.isEmpty)
                      ? _filterBar(p)
                      : const SizedBox(width: double.infinity),
            ),
            Expanded(child: _grid(p, columns)),
          ] else
            Expanded(child: _comingSoon(p, _kind)),
        ],
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
        child: TextField(
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
        ),
      );

  Widget _filterBar(AppPalette p) => Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.line)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (final f in _filters) _filterRow(p, f)],
        ),
      );

  Widget _filterRow(AppPalette p, FilterDef f) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 44,
              child: Text(f.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final o in f.options)
                      _chip(p, o.label, (_selected[f.id] ?? '') == o.value,
                          () => _pick(f.id, o.value)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

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
  Widget _mixedFilterBar(AppPalette p) => Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.line)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _mixedRow(p, '排序', const [
              ('latest', '最新更新'),
              ('popular', '人气'),
            ], _mixedSort, (v) {
              _mixedSort = v;
              _reset();
            }),
            _mixedRow(p, '进度', const [
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

  Widget _mixedRow(AppPalette p, String label, List<(String, String)> opts,
          String cur, void Function(String) onPick) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final o in opts)
                      _chip(p, o.$2, cur == o.$1, () => onPick(o.$1)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Widget _grid(AppPalette p, int columns) {
    if (_results.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      if (_error != null) return _errorView(p);
      return Center(
        child: Text('没有拿到数据',
            style: TextStyle(color: p.textMuted, fontSize: 13)),
      );
    }
    return MasonryFeed(
      controller: _scroll,
      columns: columns,
      itemCount: _results.length,
      footer: _footer(p),
      itemBuilder: (context, i) {
        final m = _results[i].manga;
        final meta = _results[i].meta;
        // 带下标:搜索/发现结果可能重复同一本,避免 Hero tag 撞车。
        final tag = 'disc:${meta.id}:${m.id}:$i';
        return FlyInUp(
          seed: m.id, // 稳定:同一张卡飞入距离/延迟不变,翻页不跳
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MangaCover(
                manga: m,
                headers: imageHeadersOf(meta),
                sourceLabel: meta.name,
                aspect: aspectForId(m.id), // 高低错落
                heroTag: tag,
                onTap: () => Navigator.of(context).push(
                  appRoute(DetailPage(manga: m, meta: meta, heroTag: tag)),
                ),
              ),
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
