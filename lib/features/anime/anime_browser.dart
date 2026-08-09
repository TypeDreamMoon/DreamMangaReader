import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/source_controller.dart';
import '../../app/theme/app_colors.dart';
import '../../core/bili/bili_auth.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/chinese_fold.dart';
import '../../core/source/models.dart';
import '../../core/source/search_rank.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../core/translate/translated_search.dart';
import '../../ui/ui.dart';
import '../common/cover_hero.dart';
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
    this.onSourceChanged,
  });

  final AnimeSourceFactory sourceBuilder;
  final List<SourceMeta>? sourceCatalog;
  final AnimeSearchVariants? searchVariants;

  /// 源配置变化时回传当前源 —— 发现页把源标签画在 tab 条右端,状态在这里。
  final ValueChanged<SourceSelection>? onSourceChanged;

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
  static const _mixedId = '__anime_all__';

  SourceMeta? _meta;
  MangaSource? _source;
  SourceController? _sourceController;
  final List<_AnimeCursor> _mixedSources = [];
  final List<_AnimeResult> _results = [];
  final Map<String, _AnimeResult> _byTitle = {};
  final Set<String> _failedSources = {};
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
    final settingChanged = showSourcePicker != _showSourcePicker;
    final mustConfigure = !_initialized ||
        controllerChanged ||
        enabledSourcesChanged ||
        settingChanged;

    if (mustConfigure) {
      if (!showSourcePicker) {
        _mixed = true;
      } else if (!_initialized || settingChanged) {
        // 首次显示或从强制混合切回时，恢复保存的单源。
        _mixed = false;
      }
      _initialized = true;
      _showSourcePicker = showSourcePicker;
      _enabledSourceSignature = signature;
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
    _notifySource();
    _reset();
  }

  /// 回传当前源。post-frame 发出 —— _configureSources 可能在 build 阶段被调用,
  /// 直接回调会在父级 setState 时炸。
  void _notifySource() {
    final notify = widget.onSourceChanged;
    if (notify == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        notify(SourceSelection(mixed: _mixed, sourceName: _meta?.name));
      }
    });
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
      _byTitle.clear();
      _failedSources.clear();
      _page = 1;
      _hasNext = true;
      _loading = false;
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
    if (_mixed) {
      if (_mixedSources.isEmpty) return;
      final generation = _loadGeneration;
      for (final cursor in _mixedSources) {
        unawaited(_loadMixedCursor(cursor, generation));
      }
      return;
    }

    if (_loading || !_hasNext || _source == null) return;
    final generation = _loadGeneration;
    setState(() => _loading = true);
    try {
      final paged = _query.isEmpty
          ? await _source!.getDiscovery(_page)
          : await _source!.getSearch(_query, _page);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        for (final anime in paged.items) {
          _addResult(anime, _meta!);
        }
        _hasNext = paged.hasNext && paged.items.isNotEmpty;
        _page++;
        _loading = false;
        _error = null;
        _sortResults();
      });
      await _maybeFallback(generation); // 搜索首页零结果 → 尝试译名回退
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
    if (cursor.loading || !cursor.hasNext) return;
    cursor.loading = true;
    if (mounted) setState(_recomputeMixedFlags);
    try {
      final paged = _query.isEmpty
          ? await cursor.source.getDiscovery(cursor.page)
          : await cursor.source.getSearch(_query, cursor.page);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        for (final anime in paged.items) {
          _addResult(anime, cursor.meta);
        }
        cursor.page++;
        cursor.hasNext = paged.hasNext && paged.items.isNotEmpty;
        cursor.failed = false;
        _failedSources.remove(cursor.meta.id);
        _sortResults();
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        cursor.failed = true;
        cursor.hasNext = false;
        _failedSources.add(cursor.meta.id);
      });
    } finally {
      if (generation == _loadGeneration) {
        cursor.loading = false;
        if (mounted) {
          setState(_recomputeMixedFlags);
          await _maybeFallback(generation);
        }
      }
    }
  }

  void _recomputeMixedFlags() {
    _loading = _mixedSources.any((cursor) => cursor.loading);
    _hasNext = _mixedSources.any((cursor) => cursor.hasNext);
    if (!_loading &&
        _results.isEmpty &&
        _mixedSources.isNotEmpty &&
        _failedSources.length == _mixedSources.length) {
      _error = context.l10n.disc_allSourcesFailed;
    }
  }

  void _addResult(Manga anime, SourceMeta meta) {
    final key = ChineseFold.dedupKey(anime.title);
    if (key.isEmpty) {
      _results.add(
        _AnimeResult(anime: anime, meta: meta)..sourceIds.add(meta.id),
      );
      return;
    }
    final existing = _byTitle[key];
    if (existing != null) {
      existing.sourceIds.add(meta.id);
      return;
    }
    final result = _AnimeResult(anime: anime, meta: meta)
      ..sourceIds.add(meta.id);
    _byTitle[key] = result;
    _results.add(result);
  }

  void _sortResults() {
    if (_origQuery.isEmpty) return;
    _results.sort((a, b) => searchRelevance(
          b.anime.title,
          _origQuery,
        ).compareTo(searchRelevance(a.anime.title, _origQuery)));
  }

  /// 搜索翻译回退:一轮搜索结束且零结果时,把原查询翻成 简/繁/英/日 逐个重搜,直到有
  /// 结果或全试完。默认开(设置「搜索翻译回退」可关)。番剧单源、顺序加载,无需代际守卫。
  Future<void> _maybeFallback(int generation) async {
    if (!mounted ||
        generation != _loadGeneration ||
        _loading ||
        _query.isEmpty ||
        _results.isNotEmpty ||
        _error != null ||
        !LibraryScope.read(context).translateSearch) {
      return;
    }
    if (_fallbackQueue == null) {
      _fallbackQueue = const [];
      final original = _origQuery;
      final store = LibraryScope.read(context);
      final variants = widget.searchVariants != null
          ? await widget.searchVariants!(original, store)
          : await TranslatedSearch.variants(
              original,
              providers: store.translateProviderOrder,
              targets: store.translateTargetsFor(original),
              llm: store.translateLlm,
            );
      if (!mounted || generation != _loadGeneration || _origQuery != original) {
        return;
      }
      _fallbackQueue = List.of(variants);
    }
    if (_fallbackQueue!.isNotEmpty) {
      _query = _fallbackQueue!.removeAt(0);
      _reset();
    }
  }

  Future<void> pickSource() async {
    final selected = await showSourcePicker(
      context,
      currentId: _mixed ? _mixedId : (_meta?.id ?? ''),
      includeMixed: true,
      mixedId: _mixedId,
      kind: 'anime',
    );
    if (selected == null || !mounted) return;
    if (selected == _mixedId) {
      if (_mixed) return;
      _mixed = true;
      _configureSources();
      return;
    }
    final meta =
        _enabledSources.where((source) => source.id == selected).firstOrNull;
    if (meta == null) return;
    _mixed = false;
    final controller = _sourceController;
    if (controller?.currentFor('anime')?.id == meta.id) {
      _configureSources();
    } else {
      controller?.selectFor('anime', meta);
    }
  }

  void _search(String q) {
    _query = q.trim();
    _origQuery = _query; // 翻译回退以它为基准
    _fallbackQueue = null; // 复位翻译回退状态
    _reset();
  }

  void _open(_AnimeResult result, {Object? heroTag}) {
    Navigator.of(context).push(appRoute(AnimeDetailPage(
      meta: result.meta,
      anime: result.anime,
      heroTag: heroTag,
      sourceBuilder: widget.sourceBuilder,
    )));
  }

  bool get _isBili => !_mixed && _meta?.id == kBiliSourceId;

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
    // 不在这里 LibraryScope.of —— 依赖已在 didChangeDependencies 注册过,
    // 源选择器也搬去发现页 tab 条了,build 里没别的要读。
    final p = context.palette;
    if (_enabledSources.isEmpty) return _noSource(p);

    return Column(
      children: [
        // 源选择(搜索已统一到发现页顶栏,这里只留源选择器)。
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
                  child: Text(context.l10n.disc_fallbackHint(_origQuery, _query),
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
                        : context.l10n.anime_biliLoggedIn)
                    : context.l10n.anime_biliLoginHint,
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
                    child: Text(context.l10n.anime_signOut))
                : FilledButton(
                    onPressed: _openBiliLogin,
                    style: FilledButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 5),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: Text(context.l10n.anime_biliScanLogin)),
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
                FilledButton(onPressed: _reset, child: Text(context.l10n.retry)),
              ],
            ),
          ),
        );
      }
      return EmptyState(title: context.l10n.anime_noContent);
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
        // 带下标:混合源翻页可能重复召回同一部番,不带就会撞 Hero tag。
        final tag = coverHeroTag(CoverHeroScope.discovery,
            sourceId: result.meta.id, itemId: m.id, index: i);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: MangaCover(
                manga: m,
                headers: imageHeadersOf(result.meta),
                sourceCount: result.sourceIds.length,
                heroTag: tag,
                onTap: () => _open(result, heroTag: tag),
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
            Text(context.l10n.anime_noSources,
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
