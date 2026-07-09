import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../core/translate/translated_search.dart';
import '../../ui/ui.dart';
import '../common/source_picker.dart';
import '../common/transitions.dart';
import '../library/manga_cover.dart';
import 'anime_detail_page.dart';

/// 发现页「番剧」档的内容:选番剧源(kind=anime)→ 热门/搜索网格 → 点卡进详情。
/// 与漫画发现的单源/混合机器完全隔离,自管一套状态,不动漫画那套。
class AnimeBrowser extends StatefulWidget {
  const AnimeBrowser({super.key});

  @override
  State<AnimeBrowser> createState() => _AnimeBrowserState();
}

class _AnimeBrowserState extends State<AnimeBrowser> {
  SourceMeta? _meta;
  MangaSource? _source;
  final List<Manga> _results = [];
  int _page = 1;
  bool _loading = false;
  bool _hasNext = true;
  String? _error;

  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  bool _showSearch = false;
  String _query = ''; // 可能是 _origQuery 的译名
  String _origQuery = ''; // 翻译回退:用户输入的原查询
  List<String>? _fallbackQueue; // 待试译名队列;null=本轮还没翻译过

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_meta == null) _pickDefault();
  }

  @override
  void dispose() {
    _source?.dispose();
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<SourceMeta> get _animeSources {
    final store = LibraryScope.read(context);
    return [
      for (final s in registeredSources)
        if (s.kind == 'anime' && store.isSourceEnabled(s.id)) s,
    ];
  }

  void _pickDefault() {
    final list = _animeSources;
    if (list.isEmpty) {
      setState(() {}); // 走空态提示
      return;
    }
    _useSource(list.first);
  }

  void _useSource(SourceMeta meta) {
    _source?.dispose();
    _meta = meta;
    _source = buildSource(meta);
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

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasNext || _source == null) return;
    setState(() => _loading = true);
    try {
      final paged = _query.isEmpty
          ? await _source!.getDiscovery(_page)
          : await _source!.getSearch(_query, _page);
      if (!mounted) return;
      setState(() {
        _results.addAll(paged.items);
        _hasNext = paged.hasNext && paged.items.isNotEmpty;
        _page++;
        _loading = false;
      });
      _maybeFallback(); // 搜索首页零结果 → 尝试译名回退
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 搜索翻译回退:一轮搜索结束且零结果时,把原查询翻成 简/繁/英/日 逐个重搜,直到有
  /// 结果或全试完。默认开(设置「搜索翻译回退」可关)。番剧单源、顺序加载,无需代际守卫。
  void _maybeFallback() {
    if (!mounted || _loading) return;
    if (_query.isEmpty || _results.isNotEmpty || _error != null) return;
    if (!LibraryScope.read(context).translateSearch) return;
    if (_fallbackQueue == null) {
      _prepareFallback();
    } else if (_fallbackQueue!.isNotEmpty) {
      _query = _fallbackQueue!.removeAt(0);
      _reset();
    }
  }

  Future<void> _prepareFallback() async {
    _fallbackQueue = const []; // 占位:翻译在途期间不再重入
    final orig = _origQuery;
    if (orig.isEmpty) return;
    final store = LibraryScope.read(context);
    final queue = await TranslatedSearch.variants(orig,
        providers: store.translateProviderOrder,
        targets: store.translateTargetsFor(orig),
        llm: store.translateLlm);
    if (!mounted || _origQuery != orig) return; // 用户中途换了查询 → 放弃
    _fallbackQueue = List.of(queue);
    if (_fallbackQueue!.isNotEmpty) {
      _query = _fallbackQueue!.removeAt(0);
      _reset();
    }
  }

  Future<void> _pickSource() async {
    if (_meta == null) return;
    final id =
        await showSourcePicker(context, currentId: _meta!.id, kind: 'anime');
    if (id == null) return;
    for (final s in registeredSources) {
      if (s.id == id) {
        _useSource(s);
        break;
      }
    }
  }

  void _search(String q) {
    _query = q.trim();
    _origQuery = _query; // 翻译回退以它为基准
    _fallbackQueue = null; // 复位翻译回退状态
    _reset();
  }

  void _open(Manga m) {
    if (_meta == null) return;
    Navigator.of(context)
        .push(appRoute(AnimeDetailPage(meta: _meta!, anime: m)));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (_animeSources.isEmpty) return _noSource(p);

    return Column(
      children: [
        // 源选择 + 搜索
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: SourcePickerPill(
                  label: '${_meta?.name ?? ''} · 番剧',
                  icon: Icons.movie_rounded,
                  onTap: _pickSource,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '搜索',
                onPressed: () => setState(() {
                  _showSearch = !_showSearch;
                  if (!_showSearch && _query.isNotEmpty) {
                    _searchCtrl.clear();
                    _search('');
                  }
                }),
                icon: Icon(_showSearch
                    ? Icons.search_off_rounded
                    : Icons.search_rounded),
              ),
            ],
          ),
        ),
        if (_showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              style: TextStyle(color: p.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索番剧名',
                hintStyle: TextStyle(color: p.textMuted),
                prefixIcon:
                    Icon(Icons.search_rounded, size: 18, color: p.textMuted),
                filled: true,
                fillColor: p.surface,
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: p.line)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: p.accent)),
              ),
            ),
          ),
        // 翻译回退提示:原文没搜到、改用译名搜到时,告诉用户用的哪个译名。
        if (_showSearch &&
            _query.isNotEmpty &&
            _query != _origQuery &&
            _results.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(Icons.translate_rounded, size: 13, color: p.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('「$_origQuery」没搜到,已用译名「$_query」',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ),
              ],
            ),
          ),
        Expanded(child: _grid(p)),
      ],
    );
  }

  Widget _grid(AppPalette p) {
    if (_results.isEmpty) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_rounded, size: 40, color: p.textMuted),
                const SizedBox(height: 12),
                SelectableText(_error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.textMuted, fontSize: 12)),
                const SizedBox(height: 12),
                FilledButton(onPressed: _reset, child: const Text('重试')),
              ],
            ),
          ),
        );
      }
      return const EmptyState(title: '没有内容');
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 168,
        crossAxisSpacing: 12,
        mainAxisSpacing: 14,
        childAspectRatio: 0.60,
      ),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final m = _results[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: MangaCover(
                manga: m,
                headers: _meta == null ? const {} : imageHeadersOf(_meta!),
                onTap: () => _open(m),
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
        );
      },
    );
  }

  Widget _noSource(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Column(
          children: [
            Icon(Icons.movie_filter_rounded, size: 44, color: p.textMuted),
            const SizedBox(height: 14),
            Text('还没有可用的番剧源',
                style: TextStyle(
                    color: p.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
            const SizedBox(height: 8),
            Text('在「设置 › 漫画源」里启用番剧源(如 AllAnime)后即可浏览。',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textMuted, fontSize: 13, height: 1.5)),
          ],
        ),
      );
}
