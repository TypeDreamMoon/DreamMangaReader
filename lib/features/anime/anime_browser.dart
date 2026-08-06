import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/source_controller.dart';
import '../../app/theme/app_colors.dart';
import '../../core/bili/bili_auth.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../core/translate/translated_search.dart';
import '../../ui/ui.dart';
import '../common/source_picker.dart';
import '../common/transitions.dart';
import '../library/manga_cover.dart';
import 'anime_detail_page.dart';
import 'bili_login_page.dart';

typedef AnimeSourceFactory = MangaSource Function(SourceMeta meta);

typedef AnimeSearchVariants = Future<List<String>> Function(
  String query,
  LibraryStore library,
);

/// 发现页「番剧」档的内容:选番剧源(kind=anime)→ 热门/搜索网格 → 点卡进详情。
/// 与漫画发现的单源/混合机器完全隔离,自管一套状态,不动漫画那套。
class AnimeBrowser extends StatefulWidget {
  const AnimeBrowser({
    super.key,
    this.sourceBuilder = buildSource,
    this.sourceCatalog,
    this.searchVariants,
  });

  final AnimeSourceFactory sourceBuilder;
  final List<SourceMeta>? sourceCatalog;
  final AnimeSearchVariants? searchVariants;

  @override
  State<AnimeBrowser> createState() => AnimeBrowserState();
}

class _AnimeResult {
  _AnimeResult({required this.anime, required this.meta});

  final Manga anime;
  final SourceMeta meta;
  final Set<String> sourceIds = {};
}

class _AnimeCursor {
  _AnimeCursor(this.meta, this.source);

  final SourceMeta meta;
  final MangaSource source;
  int page = 1;
  bool hasNext = true;
  bool loading = false;
  bool failed = false;
}

/// 公有 State:发现页用 GlobalKey 调 [runSearch] 把顶栏搜索词喂进来(搜索 UI 与漫画统一到
/// 发现页顶栏,番剧不再自带内联搜索框)。
class AnimeBrowserState extends State<AnimeBrowser> {
  SourceMeta? _meta;
  MangaSource? _source;
  SourceController? _sourceController;
  final List<_AnimeCursor> _mixedSources = [];
  final List<_AnimeResult> _results = [];
  int _page = 1;
  int _loadGeneration = 0;
  bool _initialized = false;
  bool _mixed = true;
  bool? _showSourcePicker;
  String _enabledSourceSignature = '';
  bool _loading = false;
  bool _hasNext = true;
  String? _error;

  final ScrollController _scroll = ScrollController();
  String _query = ''; // 可能是 _origQuery 的译名
  String _origQuery = ''; // 翻译回退:用户输入的原查询
  List<String>? _fallbackQueue; // 待试译名队列;null=本轮还没翻译过

  /// 发现页顶栏搜索把词喂进来(空串 = 清空回到发现)。
  void runSearch(String q) => _search(q);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = SourceScope.of(context);
    final controllerChanged = controller != _sourceController;
    if (controllerChanged) {
      _sourceController?.removeListener(_onSelectedSourceChanged);
      _sourceController = controller..addListener(_onSelectedSourceChanged);
    }

    final library = LibraryScope.of(context);
    final showSourcePicker = library.showSourcePicker;
    final signature = _enabledSources.map((source) => source.id).join('|');
    final enabledSourcesChanged = signature != _enabledSourceSignature;
    final pickerWasEnabled = _showSourcePicker == true;
    final mustConfigure = !_initialized ||
        controllerChanged ||
        enabledSourcesChanged ||
        (!showSourcePicker && !_mixed) ||
        (showSourcePicker && !pickerWasEnabled);

    _initialized = true;
    _showSourcePicker = showSourcePicker;
    _enabledSourceSignature = signature;
    if (mustConfigure) {
      // 隐藏选择器时始终使用混合源；首次显示或从隐藏切回显示时恢复保存的单源。
      _mixed = !showSourcePicker;
      _configureSources();
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _sourceController?.removeListener(_onSelectedSourceChanged);
    _disposeSources();
    _scroll.dispose();
    super.dispose();
  }

  List<SourceMeta> get _enabledSources {
    final store = LibraryScope.read(context);
    return [
      for (final source in widget.sourceCatalog ?? registeredSources)
        if (source.isAnime && store.isSourceEnabled(source.id)) source,
    ];
  }

  void _onSelectedSourceChanged() {
    if (!_mixed) _configureSources();
  }

  void _disposeSources() {
    _source?.dispose();
    _source = null;
    for (final cursor in _mixedSources) {
      cursor.source.dispose();
    }
    _mixedSources.clear();
  }

  void _configureSources() {
    _disposeSources();
    final sources = _enabledSources;
    if (_mixed) {
      _meta = null;
      for (final meta in sources) {
        _mixedSources.add(_AnimeCursor(meta, widget.sourceBuilder(meta)));
      }
    } else {
      final selected = _sourceController?.currentFor('anime');
      _meta =
          sources.where((source) => source.id == selected?.id).firstOrNull ??
              sources.firstOrNull;
      final meta = _meta;
      if (meta != null) _source = widget.sourceBuilder(meta);
    }
    _reset();
  }

  void _reset() {
    _loadGeneration++;
    for (final cursor in _mixedSources) {
      cursor
        ..page = 1
        ..hasNext = true
        ..loading = false
        ..failed = false;
    }
    setState(() {
      _results.clear();
      _page = 1;
      _hasNext = true;
      _error = null;
    });
    unawaited(_loadMore());
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasNext) return;
    if (_mixed && _mixedSources.isEmpty) return;
    if (!_mixed && _source == null) return;
    final generation = _loadGeneration;
    setState(() => _loading = true);
    if (_mixed) {
      final cursors = _mixedSources
          .where((cursor) => cursor.hasNext && !cursor.loading)
          .toList(growable: false);
      await Future.wait([
        for (final cursor in cursors) _loadMixedCursor(cursor, generation),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _hasNext = _mixedSources.any((cursor) => cursor.hasNext);
      });
      _maybeFallback();
      return;
    }
    try {
      final paged = _query.isEmpty
          ? await _source!.getDiscovery(_page)
          : await _source!.getSearch(_query, _page);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _addResults(paged.items, _meta!);
        _hasNext = paged.hasNext && paged.items.isNotEmpty;
        _page++;
        _loading = false;
      });
      _maybeFallback(); // 搜索首页零结果 → 尝试译名回退
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadMixedCursor(
    _AnimeCursor cursor,
    int generation,
  ) async {
    cursor.loading = true;
    try {
      final paged = _query.isEmpty
          ? await cursor.source.getDiscovery(cursor.page)
          : await cursor.source.getSearch(_query, cursor.page);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _addResults(paged.items, cursor.meta);
        cursor.page++;
        cursor.hasNext = paged.hasNext && paged.items.isNotEmpty;
        cursor.failed = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        cursor.failed = true;
        cursor.hasNext = false;
      });
    } finally {
      cursor.loading = false;
    }
  }

  void _addResults(List<Manga> anime, SourceMeta meta) {
    for (final item in anime) {
      _results
          .add(_AnimeResult(anime: item, meta: meta)..sourceIds.add(meta.id));
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
    for (final s in _enabledSources) {
      if (s.id == id) {
        _sourceController?.selectFor('anime', s);
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

  void _open(_AnimeResult result) {
    Navigator.of(context).push(
        appRoute(AnimeDetailPage(meta: result.meta, anime: result.anime)));
  }

  bool get _isBili => _meta?.id == kBiliSourceId;

  Future<void> _openBiliLogin() async {
    final ok =
        await Navigator.of(context).push<bool>(appRoute(const BiliLoginPage()));
    if (!mounted) return;
    if (ok == true) {
      _reset(); // 登录成功:重新拉追番
    } else {
      setState(() {}); // 刷新登录条状态
    }
  }

  Future<void> _biliLogout() async {
    await BiliAuth.instance.logout();
    if (!mounted) return;
    setState(() {});
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final p = context.palette;
    if (_enabledSources.isEmpty) return _noSource(p);

    return Column(
      children: [
        // 源选择(搜索已统一到发现页顶栏,这里只留源选择器)。
        if (library.showSourcePicker)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: SourcePickerPill(
              label: _mixed
                  ? context.l10n.disc_mixedAllSources
                  : '${_meta?.name ?? ''} · 番剧',
              icon: _mixed ? Icons.dashboard_rounded : Icons.movie_rounded,
              onTap: _pickSource,
            ),
          ),
        if (_isBili) _biliBar(p),
        // 翻译回退提示:原文没搜到、改用译名搜到时,告诉用户用的哪个译名。
        if (_query.isNotEmpty && _query != _origQuery && _results.isNotEmpty)
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

  /// B站登录条:显示登录态,提供扫码登录 / 退出入口。
  Widget _biliBar(AppPalette p) {
    final auth = BiliAuth.instance;
    final loggedIn = auth.isLoggedIn;
    final uname = auth.uname;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.line),
        ),
        child: Row(
          children: [
            Icon(
                loggedIn
                    ? Icons.verified_rounded
                    : Icons.account_circle_outlined,
                size: 18,
                color: loggedIn ? p.accent : p.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                loggedIn
                    ? (uname != null && uname.isNotEmpty
                        ? '已登录 · $uname'
                        : '已登录哔哩哔哩')
                    : '登录后可看追番、解锁大会员清晰度',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textPrimary, fontSize: 12.5),
              ),
            ),
            const SizedBox(width: 6),
            loggedIn
                ? TextButton(
                    onPressed: _biliLogout,
                    style: TextButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('退出'))
                : FilledButton(
                    onPressed: _openBiliLogin,
                    style: FilledButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 5),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('扫码登录')),
          ],
        ),
      ),
    );
  }

  Widget _grid(AppPalette p) {
    // B站不再有登录墙:未登录也能浏览「热门番剧」+ 搜索 + 看免费番(见 BiliSource.getDiscovery)。
    // 登录入口保留在上方 _biliBar,用于追番 / 解锁大会员清晰度。
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
        final result = _results[i];
        final m = result.anime;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: MangaCover(
                manga: m,
                headers: imageHeadersOf(result.meta),
                onTap: () => _open(result),
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
                style:
                    TextStyle(color: p.textMuted, fontSize: 13, height: 1.5)),
          ],
        ),
      );
}
