import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/download_store.dart';
import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../app/ui_signals.dart';
import '../../core/bangumi/bangumi_api.dart';
import '../../core/color/cover_palette.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/chapter_number.dart';
import '../../core/source/models.dart';
import '../../core/source/title_match.dart';
import '../../core/log/app_log.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../core/translate/translated_search.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import '../common/transitions.dart';
import '../library/manga_cover.dart';
import '../reader/reader_page.dart';
import 'bangumi_search_sheet.dart';
import 'cross_source_sheet.dart';

class DetailPage extends StatefulWidget {
  const DetailPage(
      {super.key, required this.manga, required this.meta, this.heroTag});

  final Manga manga;
  final SourceMeta meta;

  /// 非空时封面用 Hero 从点击处的封面飞入(须与来源封面同 tag)。
  final Object? heroTag;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final MangaSource _source = buildSource(widget.meta);
  Map<String, String> get _imgHeaders => imageHeadersOf(widget.meta);
  List<Chapter>? _chapters;
  // 库里同名书的其它源章节表:用于把跨源章节合并成一张列表(含各话由哪些源提供)。
  final List<_SrcChapters> _otherSources = [];
  bool _mergeLoading = false; // 正在找/拉其它源(主动搜索期间)
  String? _error;
  Manga? _detail; // 完整详情(简介/分级/作者),异步补,失败则退回列表级信息
  bool _descExpanded = false;
  CoverPalette? _cover; // 封面主色(KMeans),null=未算好/失败 → 退回主题色
  String? _paletteFor; // 已算过取色的封面 url(避免重复算)
  BangumiInfo? _bgm; // Bangumi 评分(置信匹配到才有,否则 null)
  bool _bgmLoading = true; // Bangumi 匹配中(区分「加载中」和「没匹配到」)
  bool _bgmSummaryExpanded = false; // Bangumi 简介是否展开
  List<BangumiCandidate> _recommend = const []; // Bangumi 相关推荐
  bool _recOpening = false; // 正在为某条推荐找可读的源
  late Object _tintToken; // 全局背景封面色的栈 token(本页在栈,离开出栈)
  Color? _coverTint; // 算好的封面色(取消返回时用它重新压栈)
  bool _tintPushed = true; // 封面色当前是否在栈里
  ModalRoute<Object?>? _route; // 监听本页路由动画,返回一开始就出栈(不等 dispose)

  /// 渲染用的合并信息:优先完整详情,字段缺失时退回列表传入的 [widget.manga]。
  Manga get _manga {
    final d = _detail;
    if (d == null) return widget.manga;
    return Manga(
      id: widget.manga.id,
      title: d.title.isNotEmpty ? d.title : widget.manga.title,
      cover: (d.cover != null && d.cover!.isNotEmpty) ? d.cover : widget.manga.cover,
      url: (d.url != null && d.url!.isNotEmpty) ? d.url : widget.manga.url,
      authors: d.authors.isNotEmpty ? d.authors : widget.manga.authors,
      genres: d.genres.isNotEmpty ? d.genres : widget.manga.genres,
      description: (d.description != null && d.description!.isNotEmpty)
          ? d.description
          : widget.manga.description,
      status: d.status != MangaStatus.unknown ? d.status : widget.manga.status,
    );
  }

  @override
  void initState() {
    super.initState();
    _tintToken = DetailTint.push(); // 进入详情:入栈(取色算好后 update)
    _load();
    _loadDetail();
    _extractPalette();
    _loadBangumi();
    _loadOtherSources();
  }

  SourceMeta? _metaById(String id) {
    for (final s in registeredSources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 拉**其它源**的同名书章节表,合并成跨源章节列表(A 源多出来的话混进 B 源)。
  /// 两路来源:① 库里(收藏∪历史)已知 mangaId 的源(免搜);② 其它已启用源**主动搜**
  /// 书名、按「同作品(容繁简/副标题)」匹配。各源失败/无匹配静默跳过;dispose 释放引擎。
  Future<void> _loadOtherSources() async {
    final store = LibraryScope.read(context);
    if (coreTitle(widget.manga.title).isEmpty) return;

    // ① 库里同名书(已知 mangaId,记它自己的标题/封面以免打开时串成当前源的元数据)。
    final lib = <String, ({String mangaId, String title, String? cover})>{};
    void consider(String title, String sid, String mid, String? cover) {
      if (sid == widget.meta.id || lib.containsKey(sid)) return;
      if (sameWork(title, widget.manga.title)) {
        lib[sid] = (mangaId: mid, title: title, cover: cover);
      }
    }

    for (final f in store.favorites) {
      consider(f.title, f.sourceId, f.mangaId, f.cover);
    }
    for (final h in store.history) {
      consider(h.title, h.sourceId, h.mangaId, h.cover);
    }

    // ② 其它已启用、未覆盖的漫画源 → 主动搜书名找同作品。
    final covered = {widget.meta.id, ...lib.keys};
    final toSearch = [
      for (final s in registeredSources)
        if (s.kind == 'manga' &&
            store.isSourceEnabled(s.id) &&
            !covered.contains(s.id))
          s,
    ];
    if (lib.isEmpty && toSearch.isEmpty) return;

    // 增量:每个源各自拉、拉好一个就并进来一个(不等全部),慢源不拖住已到的。
    // initState 同步段直接赋值(首帧构建会读到);await 后才走真正的 setState。
    _mergeLoading = true;
    var pending = lib.length + toSearch.length;
    void addOne(_SrcChapters sc) {
      if (!mounted) {
        sc.source.dispose(); // 页已销毁:别加,直接释放引擎
        return;
      }
      setState(() => _otherSources.add(sc));
    }

    void done() {
      pending--;
      if (pending <= 0 && mounted) setState(() => _mergeLoading = false);
    }

    // 库里源:mangaId 已知,直接取章节。buildSource 放进 try —— 脚本损坏只跳过该源。
    for (final e in lib.entries) {
      () async {
        MangaSource? src;
        try {
          final meta = _metaById(e.key);
          if (meta != null) {
            src = buildSource(meta);
            final page = await src.getChapters(e.value.mangaId);
            addOne(_SrcChapters(meta, src, e.value.mangaId, e.value.title,
                e.value.cover, page.items));
            src = null; // 已交给 addOne(成功则进 _otherSources,失败则它已 dispose)
          }
        } catch (_) {
          src?.dispose();
        } finally {
          done();
        }
      }();
    }
    // 逐源搜书名时的翻译回退:原名没命中就试译名(简/繁/英/日),补齐跨语言的源。
    // 懒触发:只有某源真的没命中原名时才翻译一次,各源共享;全命中/设置关则永不翻译。
    Future<List<String>>? variantsFuture;
    Future<List<String>> variants() => variantsFuture ??= store.translateSearch
        ? TranslatedSearch.variants(widget.manga.title,
            providers: store.translateProviderOrder, llm: store.translateLlm)
        : Future<List<String>>.value(const []);
    // 主动搜索源:先搜、匹配同作品、再取章节。
    for (final meta in toSearch) {
      () async {
        MangaSource? src;
        try {
          src = buildSource(meta);
          final match = await _searchWork(src, variants);
          if (match != null) {
            final page = await src.getChapters(match.id);
            addOne(_SrcChapters(
                meta, src, match.id, match.title, match.cover, page.items));
            src = null;
          }
        } catch (_) {
        } finally {
          src?.dispose(); // 无匹配/异常:释放;成功已置 null 不重复释放
          done();
        }
      }();
    }
  }

  /// 在 [src] 里按当前书名找同作品:先搜原名,没命中再逐个试 [variants] 译名
  /// (译名列表懒求值:只有原名没命中才会触发翻译)。
  Future<Manga?> _searchWork(
      MangaSource src, Future<List<String>> Function() variants) async {
    final title = widget.manga.title;
    final orig = await src.getSearch(title, 1);
    for (final m in orig.items) {
      if (sameWork(m.title, title)) return m;
    }
    for (final v in await variants()) {
      final r = await src.getSearch(v, 1);
      for (final m in r.items) {
        if (sameWork(m.title, v)) return m;
      }
    }
    return null;
  }

  /// 把当前源 + 其它源的章节按话数合并成一张列表。
  /// - 当前源章节**全保留**(含 上/下 拆章、无号章),不因同话数被折叠;
  /// - 他源命中已有话数 → 记为该话的「提供源」;他源独有的话数 → 作为补充章加入;
  /// - 按话数稳定升序(等号保原序,上/下 不乱;无号章沉底)。
  List<_MergedChapter> _mergedChapters() {
    final current = _chapters ?? const <Chapter>[];
    final rows = <_MergedChapter>[];
    final currentByNumber = <double, List<_MergedChapter>>{}; // 挂他源 provider 用
    final extraByNumber = <double, _MergedChapter>{}; // 他源独有话数

    for (final c in current) {
      final n = parseChapterNumber(c.name);
      final row = _MergedChapter(
          n, c.name, [_ChapterProvider(widget.meta, _source, c, widget.manga.id)]);
      rows.add(row);
      if (n != null) (currentByNumber[n] ??= []).add(row);
    }
    for (final os in _otherSources) {
      for (final c in os.chapters) {
        final n = parseChapterNumber(c.name);
        if (n == null) continue; // 他源无号章无法对齐,忽略
        final prov = _ChapterProvider(os.meta, os.source, c, os.mangaId);
        final curRows = currentByNumber[n];
        if (curRows != null) {
          // 当前源已有该话(可能上/下多行)→ 只挂到第一行,避免重复挂。
          final r = curRows.first;
          if (!r.providers.any((pv) => pv.meta.id == os.meta.id)) {
            r.providers.add(prov);
          }
        } else {
          final er = extraByNumber[n];
          if (er == null) {
            final row = _MergedChapter(n, c.name, [prov]);
            extraByNumber[n] = row;
            rows.add(row);
          } else if (!er.providers.any((pv) => pv.meta.id == os.meta.id)) {
            er.providers.add(prov);
          }
        }
      }
    }
    // 稳定升序:等话数按原序(上/下不乱),无号章(null)沉底。
    final indexed = [for (var i = 0; i < rows.length; i++) (i, rows[i])];
    indexed.sort((a, b) {
      final an = a.$2.number ?? double.infinity;
      final bn = b.$2.number ?? double.infinity;
      final c = an.compareTo(bn);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// 打开合并列表里的一话:优先用当前源打开(老路径),否则用提供它的他源引擎打开。
  void _openMerged(_MergedChapter row, {int initialPage = 0}) {
    _ChapterProvider? cur;
    for (final pv in row.providers) {
      if (pv.meta.id == widget.meta.id) {
        cur = pv;
        break;
      }
    }
    final prov = cur ?? row.providers.first;
    if (prov.meta.id == widget.meta.id) {
      _openChapter(prov.chapter, initialPage: initialPage);
      return;
    }
    // 他源:用它的引擎 + 它的章节表打开(进度记在它自己的 sid:mid 下,共享进度仍按标题汇合)。
    final os = _otherSources.firstWhere((o) => o.meta.id == prov.meta.id);
    var idx = os.chapters.indexWhere((x) => x.id == prov.chapter.id);
    if (idx < 0) idx = 0;
    Navigator.of(context).push(appRoute(ReaderPage(
      source: os.source,
      // 用他源自己的书名/封面(进度记在它 sid:mid 下,元数据别串成当前源的)。
      manga: Manga(id: os.mangaId, title: os.title, cover: os.cover),
      chapters: os.chapters,
      index: idx,
      imageHeaders: imageHeadersOf(os.meta),
    )));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = ModalRoute.of(context);
    if (r != _route) {
      _route?.animation?.removeStatusListener(_onRouteAnim);
      _route = r;
      _route?.animation?.addStatusListener(_onRouteAnim);
    }
  }

  // 本页路由的入场动画:reverse/dismissed = 正在返回 → 立刻把封面色出栈,
  // 背景在「离开动画」里就渐变回设置色,而不是等到已经在书架上才闪一下。
  void _onRouteAnim(AnimationStatus s) {
    final leaving =
        s == AnimationStatus.reverse || s == AnimationStatus.dismissed;
    if (leaving && _tintPushed) {
      _tintPushed = false;
      DetailTint.pop(_tintToken);
    } else if (!leaving && !_tintPushed && mounted) {
      _tintPushed = true; // 取消返回手势 → 重新压回封面色
      _tintToken = DetailTint.push(_coverTint);
    }
  }

  /// 去 Bangumi 查评分/元数据。优先用手动绑定的条目;否则标题置信匹配。
  /// 匹配不上不再静默——展示「未找到」+ 手动搜索入口。
  Future<void> _loadBangumi() async {
    final key = '${widget.meta.id}:${widget.manga.id}';
    final bound = LibraryScope.read(context).bangumiBindingFor(key);
    BangumiInfo? info;
    if (bound != null) {
      // 有手动绑定:只认它。加载失败(如条目已 404 / 暂时断网)**不回退自动匹配**,
      // 否则会用一个「可能正是用户当初否掉的」错误条目悄悄顶替。留 null → 显示未找到/重新匹配,
      // 且保留绑定(网络恢复后下次自然加载回来)。
      info = await BangumiApi.fromId(bound);
    } else {
      info = await BangumiApi.lookup(widget.manga.title);
    }
    if (!mounted) return;
    setState(() {
      _bgm = info;
      _bgmLoading = false;
    });
    if (info != null) _loadRecommend(info);
  }

  /// 拉 Bangumi 相关推荐(相关条目 + 题材同类)。失败静默。
  Future<void> _loadRecommend(BangumiInfo info) async {
    final recs = await BangumiApi.recommend(info);
    if (mounted) setState(() => _recommend = recs);
  }

  /// 点某条推荐 → 在已启用源里并发搜同名,找到就打开它的详情页;没有则提示。
  Future<void> _openRecommend(BangumiCandidate rec) async {
    if (_recOpening) return;
    final title = rec.display;
    final store = LibraryScope.read(context);
    final metas = [
      for (final s in registeredSources)
        if (s.kind == 'manga' && store.isSourceEnabled(s.id)) s,
    ];
    if (metas.isEmpty) return;
    setState(() => _recOpening = true);
    showAppNotify(context, '在源里找《$title》…', kind: AppNotifyKind.info);
    // 先搜原名;没命中、且不是「全源都报错」(断网/全限流时翻译再搜无意义)→ 翻成
    // 简/繁/英/日 逐个再搜(受设置「搜索翻译回退」开关控制),中途若全源报错则停。
    var r = await _findInSources(metas, title);
    var found = r.match;
    if (found == null && !r.allErrored && store.translateSearch) {
      for (final v in await TranslatedSearch.variants(title,
          providers: store.translateProviderOrder, llm: store.translateLlm)) {
        r = await _findInSources(metas, v);
        if (r.match != null) {
          found = r.match;
          break;
        }
        if (r.allErrored) break; // 全源挂了:别再对着已挂的源试下一个译名
      }
    }
    if (!mounted) return;
    setState(() => _recOpening = false);
    if (found == null) {
      showAppNotify(context, '源里没找到《$title》', kind: AppNotifyKind.info);
      return;
    }
    Navigator.of(context).push(
        appRoute(DetailPage(manga: found.manga, meta: found.meta)));
  }

  /// 在给定源里并发搜 [query],返回第一个 [sameWork] 命中;[allErrored]=所有源都抛错
  /// (区分「真没搜到」与「全源失败」——后者不该触发翻译回退)。
  Future<({({SourceMeta meta, Manga manga})? match, bool allErrored})>
      _findInSources(List<SourceMeta> metas, String query) async {
    ({SourceMeta meta, Manga manga})? found;
    var okCount = 0; // 成功返回(未抛错)的源数
    await Future.wait(metas.map((meta) async {
      if (found != null) return;
      final src = buildSource(meta);
      try {
        final r = await src.getSearch(query, 1);
        okCount++;
        for (final m in r.items) {
          if (sameWork(m.title, query)) {
            found ??= (meta: meta, manga: m);
            break;
          }
        }
      } catch (_) {
      } finally {
        src.dispose();
      }
    }));
    return (match: found, allErrored: okCount == 0 && metas.isNotEmpty);
  }

  /// 相关推荐:横向封面条(Bangumi 相关条目 + 题材同类)。点击去源里找并打开。
  Widget _recommendSection(AppPalette p) {
    if (_recommend.isEmpty) return const SizedBox.shrink();
    final acc = _cover?.primary ?? p.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Text('相关推荐',
                  style: TextStyle(
                      color: Color.lerp(p.textPrimary, acc, 0.4),
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
              const SizedBox(width: 6),
              if (_recOpening)
                SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: p.textMuted)),
            ],
          ),
        ),
        SizedBox(
          height: 168,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _recommend.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) => _recCard(p, _recommend[i]),
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _recCard(AppPalette p, BangumiCandidate rec) {
    final grad = coverGradient('${rec.id}');
    return SizedBox(
      width: 88,
      child: Pressable(
        onTap: () => _openRecommend(rec),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 3 / 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(context.radius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: grad),
                      ),
                    ),
                    if (rec.image.isNotEmpty)
                      CachedNetworkImage(
                        cacheManager: appImageCache,
                        imageUrl: rec.image,
                        fit: BoxFit.cover,
                        fadeInDuration: const Duration(milliseconds: 180),
                        errorWidget: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    if (rec.score > 0)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.66),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(rec.score.toStringAsFixed(1),
                              style: TextStyle(
                                  color: p.bangumi,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(rec.display,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 11,
                    height: 1.2,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  /// 手动搜索 Bangumi 并绑定(自动匹配不准/没匹配到时用)。绑定会持久化。
  Future<void> _openBangumiSearch() async {
    final picked = await showAppSheet<BangumiCandidate>(
      context,
      title: '搜索 Bangumi',
      showCloseButton: true,
      resizeForKeyboard: true,
      heightFactor: 0.7,
      body: (ctx, setSheet) =>
          BangumiSearchSheet(initialQuery: widget.manga.title),
    );
    if (picked == null || !mounted) return;
    setState(() => _bgmLoading = true);
    // 先确认能拉到条目,**成功后再写绑定**——避免存下一个坏绑定、
    // 或因加载失败把刚选好的条目错误地掉回「未找到」空状态。
    final info = await BangumiApi.fromId(picked.id);
    if (!mounted) return;
    if (info == null) {
      setState(() => _bgmLoading = false); // 保留原卡片状态,只提示
      showAppNotify(context, '加载该条目失败,请重试', kind: AppNotifyKind.error);
      return;
    }
    final key = '${widget.meta.id}:${widget.manga.id}';
    LibraryScope.read(context).setBangumiBinding(key, picked.id);
    setState(() {
      _bgm = info;
      _bgmLoading = false;
    });
    _loadRecommend(info);
  }

  /// 换源:在其它已启用源里搜同名漫画,选中后用该源重开详情页(替换当前页,
  /// 返回即回到来处)。当前源不在候选内。
  Future<void> _openCrossSource() async {
    final picked = await showAppSheet<CrossSourcePick>(
      context,
      title: '换源',
      showCloseButton: true,
      resizeForKeyboard: true,
      heightFactor: 0.7,
      body: (ctx, setSheet) => CrossSourceSheet(
        title: _manga.title,
        currentSourceId: widget.meta.id,
      ),
    );
    if (picked == null || !mounted) return;
    Navigator.of(context).pushReplacement(
      appRoute(DetailPage(manga: picked.manga, meta: picked.meta)),
    );
  }

  /// 从封面算主色(KMeans),用来给详情页头部/按钮染色。失败静默,保持主题色。
  Future<void> _extractPalette() async {
    final url = _manga.cover;
    if (url == null || url.isEmpty || url == _paletteFor) return;
    _paletteFor = url;
    final pal = await extractCoverPalette(url, _imgHeaders);
    if (mounted && pal != null) {
      setState(() => _cover = pal);
      _coverTint = pal.primary;
      if (_tintPushed) {
        DetailTint.update(_tintToken, pal.primary); // 让全局背景在本页混入封面主题色
      }
    }
  }

  Future<void> _load() async {
    final sw = Stopwatch()..start();
    try {
      final page = await _source.getChapters(widget.manga.id);
      if (mounted) setState(() => _chapters = page.items);
      AppLog.i.info(LogCat.manga,
          '加载章节《${widget.manga.title}》· ${page.items.length} 话 · ${sw.elapsedMilliseconds}ms',
          detail: '源:${widget.meta.name} · id=${widget.manga.id}');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      AppLog.i.err(LogCat.manga, '加载章节《${widget.manga.title}》失败',
          detail: '源:${widget.meta.name}\n$e');
    }
  }

  /// 重新加载当前源章节(章节加载失败时的「重新加载」按钮)。清错 + 回加载态再拉一次。
  void _reloadChapters() {
    setState(() {
      _error = null;
      _chapters = null;
    });
    _load();
  }

  Future<void> _loadDetail() async {
    try {
      final d = await _source.getMangaDetail(widget.manga.id);
      if (mounted) setState(() => _detail = d);
      _extractPalette(); // 详情封面可能比列表更清晰,重算(url 不变则跳过)
    } catch (_) {
      // 详情拿不到不致命——头部退回列表级信息。
    }
  }

  Future<void> _openInBrowser() async {
    final raw = _manga.url;
    if (raw == null || raw.isEmpty) return;
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showAppNotify(context, '打不开链接:$raw', kind: AppNotifyKind.error);
    }
  }

  void _openChapter(Chapter c, {int initialPage = 0}) {
    final list = _chapters ?? [c];
    var idx = list.indexWhere((x) => x.id == c.id);
    if (idx < 0) idx = 0;
    Navigator.of(context).push(
      appRoute(ReaderPage(
        source: _source,
        manga: widget.manga,
        chapters: list,
        index: idx,
        imageHeaders: _imgHeaders,
        initialPage: initialPage,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final acc = _cover?.primary ?? p.accent; // 封面主题色
    final store = LibraryScope.of(context); // 依赖:收藏/进度变了自动重建
    final dl = DownloadScope.of(context); // 依赖:下载状态变了刷新按钮
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: '换源',
            onPressed: _openCrossSource,
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
          const SizedBox(width: 4),
        ],
        // 毛玻璃:模糊身后封面 + 顶部渐深遮罩,让返回/操作图标在任意封面上都清晰。
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.38),
                    Colors.black.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      // 全页融入封面主题色:顶部一层淡淡的封面色,向下渐隐,叠在全局背景之上。
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [acc.withValues(alpha: 0.16), Colors.transparent],
            stops: const [0.0, 0.55],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 760
              ? _wideBody(p, store, dl) // 横屏/桌面:左信息 + 右章节
              : _narrowBody(p, store, dl), // 竖屏:单列纵向滚动
        ),
      ),
    );
  }

  /// 竖屏:信息 + 章节单列纵向滚动。
  Widget _narrowBody(AppPalette p, LibraryStore store, DownloadStore dl) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: CustomScrollView(
            // 章节走惰性 SliverList:上千章也只建可见行(否则全建出来又卡又刷爆语义树)。
            slivers: [
              SliverToBoxAdapter(child: _hero(p)),
              SliverToBoxAdapter(child: _cta(p, store, dl)),
              SliverToBoxAdapter(child: _bangumiCard(p)),
              SliverToBoxAdapter(child: _synopsis(p)),
              SliverToBoxAdapter(child: _recommendSection(p)),
              ..._chapterSlivers(p, store, dl),
            ],
          ),
        ),
      );

  /// 横屏/桌面:左列固定宽度(封面/信息/按钮/简介,独立滚动),右列章节表(独立滚动)。
  Widget _wideBody(AppPalette p, LibraryStore store, DownloadStore dl) {
    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 380,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 28),
                child: Column(
                  children: [
                    _hero(p),
                    _cta(p, store, dl),
                    _bangumiCard(p),
                    _synopsis(p),
                    _recommendSection(p),
                  ],
                ),
              ),
            ),
            VerticalDivider(width: 1, thickness: 1, color: p.line),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  // 右列顶部让开透明 AppBar。
                  SliverToBoxAdapter(child: SizedBox(height: topInset)),
                  ..._chapterSlivers(p, store, dl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(AppPalette p) {
    final m = _manga;
    final grad = coverGradient(widget.manga.id);
    final cover = m.cover;
    final acc = _cover?.primary ?? p.accent;
    final gradTop = _cover?.primary ?? grad.first;
    final gradBot = _cover?.secondary ?? grad.last;
    return SizedBox(
      height: 268,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 450),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [gradTop.withValues(alpha: 0.9), gradBot],
              ),
            ),
          ),
          if (cover != null && cover.isNotEmpty)
            ExcludeSemantics(
              child: Opacity(
                opacity: 0.55,
                child: CachedNetworkImage(
                  cacheManager: appImageCache,
                  imageUrl: cover,
                  httpHeaders: _imgHeaders,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const SizedBox.shrink(),
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  p.background.withValues(alpha: 0.25),
                  p.background.withValues(alpha: 0.7),
                  p.background,
                ],
                stops: const [0.0, 0.65, 1.0],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 88,
                  child: MangaCover(
                    manga: m,
                    headers: _imgHeaders,
                    radius: 12,
                    heroTag: widget.heroTag,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 来源角标
                      AppPill(
                        text: widget.meta.name,
                        fill: acc.withValues(alpha: 0.16),
                        textColor: Color.lerp(acc, Colors.white, 0.35),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        radius: 6,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        m.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                      if (m.authors.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text('作者 · ${m.authors.join('、')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(color: p.textMuted, fontSize: 12)),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _pill(p, _statusText(m.status),
                              accent: true, accentColor: acc),
                          for (final t in m.genres.take(6)) _pill(p, t),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _statusText(MangaStatus s) {
    switch (s) {
      case MangaStatus.ongoing:
        return '● 连载中';
      case MangaStatus.completed:
        return '● 完结';
      case MangaStatus.hiatus:
        return '● 休刊';
      case MangaStatus.cancelled:
        return '● 停载';
      case MangaStatus.unknown:
        return '● 未知';
    }
  }

  Widget _pill(AppPalette p, String text,
      {bool accent = false, Color? accentColor}) {
    final a = accentColor ?? p.accent;
    return AppPill(
      text: text,
      fill: accent ? a.withValues(alpha: 0.16) : p.surface,
      border: accent ? a.withValues(alpha: 0.45) : p.line,
      textColor: accent ? Color.lerp(a, Colors.white, 0.25) : p.textMuted,
    );
  }

  /// 继续阅读目标:取「本源本地进度」与「跨源作品共享进度」里更靠后的一个 → (章节, 页)。
  /// 作品进度(他源读到的)更靠后时,映射到本源话数相同(或最接近且 ≤)的那章,从头读起
  /// (页码不跨源共享)。都没有则 null。
  ({Chapter chapter, int page})? _resume(LibraryStore store) {
    final chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return null;

    // 本源本地续读点。
    Chapter? localCh;
    var localPage = 0;
    var localNum = double.negativeInfinity;
    final st = store.readState(widget.meta.id, widget.manga.id);
    if (st != null && st.lastChapterId.isNotEmpty) {
      for (final c in chapters) {
        if (c.id == st.lastChapterId) {
          localCh = c;
          localPage = st.lastPage;
          localNum = parseChapterNumber(c.name) ?? double.negativeInfinity;
          break;
        }
      }
    }

    // 作品级共享续读点(话数):仅在「本地没读过」或「本地那章能解析话数且作品更靠后」时,
    // 才映射到本源对应章。本地最后读的是**无号章**(番外/特别篇,localNum=-inf)时**尊重它**,
    // 别被作品话数顶回更早的编号章(否则会把用户弹回旧位置)。
    final workNum = store.workProgressFor(widget.manga.title)?.chapterNumber;
    final useWork = workNum != null &&
        (localCh == null || (localNum.isFinite && workNum > localNum));
    if (useWork) {
      final target = _chapterForNumber(chapters, workNum);
      if (target != null) {
        // 命中的正好是本地那章 → 保留页码;否则从头(他源的页码不通用)。
        final page = target.id == localCh?.id ? localPage : 0;
        return (chapter: target, page: page);
      }
    }
    if (localCh != null) return (chapter: localCh, page: localPage);
    return null;
  }

  /// 在章节表里找话数 == [target] 的章;没有则取话数 ≤ target 的最大那章(尽力对齐)。
  Chapter? _chapterForNumber(List<Chapter> chapters, double target) {
    Chapter? floor;
    var floorNum = double.negativeInfinity;
    for (final c in chapters) {
      final n = parseChapterNumber(c.name);
      if (n == null) continue;
      if (n == target) return c;
      if (n < target && n > floorNum) {
        floorNum = n;
        floor = c;
      }
    }
    return floor;
  }

  Widget _cta(AppPalette p, LibraryStore store, DownloadStore dl) {
    final chapters = _chapters;
    final fav = store.isFavorite(widget.meta.id, widget.manga.id);
    final resume = _resume(store); // 读过 → 主按钮变「继续阅读」
    final canRead = chapters != null && chapters.isNotEmpty;
    final acc = _cover?.primary ?? p.accent;
    final accOn = _cover?.onPrimary ?? p.onAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: !canRead
                  ? null
                  : (resume != null
                      ? () => _openChapter(resume.chapter,
                          initialPage: resume.page)
                      : () => _openChapter(chapters.first)), // 升序:第一条=第1话
              style: FilledButton.styleFrom(
                  backgroundColor: acc,
                  foregroundColor: accOn,
                  minimumSize: const Size.fromHeight(46)),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(resume != null ? Icons.play_circle_fill_rounded : Icons.play_arrow_rounded,
                      size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      resume != null ? '继续 · ${resume.chapter.name}' : '从头开始',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          _iconBtn(
            p,
            fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            active: fav,
            accent: acc,
            onTap: () => store.toggleFavorite(FavoriteEntry(
              sourceId: widget.meta.id,
              mangaId: widget.manga.id,
              title: widget.manga.title,
              cover: widget.manga.cover,
              addedAt: DateTime.now().millisecondsSinceEpoch,
            )),
          ),
          const SizedBox(width: 10),
          _iconBtn(
            p,
            Icons.download_rounded,
            accent: acc,
            onTap: (chapters != null && chapters.isNotEmpty)
                ? () => _downloadAll(dl, chapters)
                : null,
          ),
          if (_manga.url != null && _manga.url!.isNotEmpty) ...[
            const SizedBox(width: 10),
            _iconBtn(p, Icons.open_in_browser_rounded,
                accent: acc, onTap: _openInBrowser),
          ],
        ],
      ),
    );
  }

  Future<void> _downloadAll(DownloadStore dl, List<Chapter> chapters) async {
    final todo = chapters
        .where((c) => !dl.isDownloaded(widget.meta.id, widget.manga.id, c.id))
        .toList();
    if (todo.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载全部'),
        content: Text('将下载 ${todo.length} 话到本地,可离线阅读。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('下载')),
        ],
      ),
    );
    if (ok != true) return;
    for (final c in todo) {
      dl.enqueue(widget.meta, widget.manga, c, _imgHeaders);
    }
    if (mounted) {
      showAppNotify(context, '已加入下载队列 · ${todo.length} 话',
          kind: AppNotifyKind.success);
    }
  }

  Widget _iconBtn(AppPalette p, IconData icon,
      {bool active = false, VoidCallback? onTap, Color? accent}) {
    final a = accent ?? p.accent;
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: active ? a.withValues(alpha: 0.16) : p.elevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? a : p.line),
        ),
        // 图标切换(如收藏♥↔♡)带缩放弹一下。
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(icon,
              key: ValueKey('$icon$active'),
              color: active ? a : p.textPrimary,
              size: 20),
        ),
      ),
    );
  }

  /// 简介卡:完整详情拿到后显示,长文可展开/收起。
  Widget _synopsis(AppPalette p) {
    // 源没给简介 → 退回 Bangumi 的简介(有匹配到条目时)。
    var desc = (_manga.description ?? '').trim();
    var fromBangumi = false;
    if (desc.isEmpty) {
      desc = (_bgm?.summary ?? '').trim();
      fromBangumi = desc.isNotEmpty;
    }
    if (desc.isEmpty) return const SizedBox.shrink();
    final acc = _cover?.primary ?? p.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(context.radius),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('简介',
                    style: TextStyle(
                        color: acc,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0)),
                if (fromBangumi) ...[
                  const SizedBox(width: 6),
                  Text('· 来自 Bangumi',
                      style: TextStyle(color: p.textMuted, fontSize: 10.5)),
                ],
              ],
            ),
            const SizedBox(height: 8),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: Text(
                desc,
                maxLines: _descExpanded ? null : 4,
                overflow: _descExpanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: TextStyle(
                    color: p.textPrimary.withValues(alpha: 0.82),
                    fontSize: 13,
                    height: 1.55),
              ),
            ),
            if (desc.length > 90) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(() => _descExpanded = !_descExpanded),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_descExpanded ? '收起' : '展开全部',
                        style: TextStyle(
                            color: acc,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                    AnimatedRotation(
                      turns: _descExpanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.keyboard_arrow_down_rounded,
                          color: acc, size: 18),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bgmIcon(AppPalette p, IconData icon, String tip, VoidCallback onTap) =>
      IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        color: p.textMuted,
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      );

  /// Bangumi 卡:加载中 / 未匹配(可手动搜索)/ 匹配到(评分 + 制作信息 + 简介)。
  Widget _bangumiCard(AppPalette p) {
    Widget shell(Widget child) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(context.radius),
              border: Border.all(color: p.line),
            ),
            child: child,
          ),
        );

    if (_bgmLoading) {
      return shell(Row(
        children: [
          SizedBox(
              width: 15,
              height: 15,
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: p.bangumi)),
          const SizedBox(width: 10),
          Text('正在匹配 Bangumi…',
              style: TextStyle(color: p.textMuted, fontSize: 12)),
        ],
      ));
    }

    final b = _bgm;
    if (b == null) {
      return shell(Row(
        children: [
          Icon(Icons.search_off_rounded, size: 18, color: p.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Bangumi 未找到匹配条目',
                style: TextStyle(color: p.textMuted, fontSize: 12.5)),
          ),
          TextButton.icon(
            onPressed: _openBangumiSearch,
            icon: const Icon(Icons.search_rounded, size: 16),
            label: const Text('手动搜索'),
            style: TextButton.styleFrom(
                foregroundColor: p.bangumi,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          ),
        ],
      ));
    }

    final filled = (b.score / 2).floor();
    final half = (b.score / 2 - filled) >= 0.5;
    final metaBits = <String>[
      if (b.date.isNotEmpty) b.date,
      if (b.volumes > 0) '${b.volumes} 卷',
      if (b.eps > 0) '${b.eps} 话',
    ];
    return shell(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Bangumi',
                style: TextStyle(
                    color: p.bangumi,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0)),
            const Spacer(),
            _bgmIcon(p, Icons.search_rounded, '重新匹配', _openBangumiSearch),
            const SizedBox(width: 2),
            _bgmIcon(
                p,
                Icons.open_in_new_rounded,
                '在 Bangumi 打开',
                () => launchUrl(Uri.parse(b.url),
                    mode: LaunchMode.externalApplication)),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(b.score.toStringAsFixed(1),
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    height: 1.0)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    for (var i = 0; i < 5; i++)
                      Icon(
                          i < filled
                              ? Icons.star_rounded
                              : (i == filled && half
                                  ? Icons.star_half_rounded
                                  : Icons.star_border_rounded),
                          size: 15,
                          color: p.bangumi),
                  ]),
                  const SizedBox(height: 4),
                  Text('${b.rank > 0 ? '#${b.rank} · ' : ''}${b.votesLabel}',
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(b.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: p.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
        if (b.nameOrig.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(b.nameOrig,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textMuted, fontSize: 11)),
          ),
        if (metaBits.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(metaBits.join('  ·  '),
              style: TextStyle(color: p.textMuted, fontSize: 11)),
        ],
        if (b.infobox.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final row in b.infobox.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(row.$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textMuted, fontSize: 11)),
                  ),
                  Expanded(
                    child: Text(row.$2,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textPrimary, fontSize: 11)),
                  ),
                ],
              ),
            ),
        ],
        if (b.tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in b.tags.take(8))
                AppPill(
                  text: t,
                  fill: p.bangumi.withValues(alpha: 0.10),
                  textColor: Color.lerp(p.bangumi, Colors.white, 0.3),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  radius: 6,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                ),
            ],
          ),
        ],
        if (b.summary.isNotEmpty) ...[
          const SizedBox(height: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                setState(() => _bgmSummaryExpanded = !_bgmSummaryExpanded),
            child: AnimatedSize(
              duration: LibraryStore.animationsEnabled
                  ? const Duration(milliseconds: 220)
                  : Duration.zero,
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: Text(b.summary,
                  maxLines: _bgmSummaryExpanded ? null : 3,
                  overflow: _bgmSummaryExpanded
                      ? TextOverflow.clip
                      : TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.textMuted, fontSize: 11.5, height: 1.5)),
            ),
          ),
        ],
      ],
    ));
  }

  // 单个源的供给角标(章节行下方):当前源用强调色,他源用弱底色。
  Widget _srcChip(AppPalette p, String name, bool current) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: current ? p.accent.withValues(alpha: 0.16) : p.background,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
              color: current ? p.accent.withValues(alpha: 0.4) : p.line),
        ),
        child: Text(name,
            style: TextStyle(
                color: current ? p.accent : p.textMuted,
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                height: 1.1)),
      );

  Widget _chapterRow(
      AppPalette p, LibraryStore store, _MergedChapter row, DownloadStore dl) {
    final multi = _otherSources.isNotEmpty; // 有他源才展示「哪些源提供」的角标
    // 当前源是否提供本话 → 用它的本地标记算 finished/页码/下载。
    _ChapterProvider? cur;
    for (final pv in row.providers) {
      if (pv.meta.id == widget.meta.id) {
        cur = pv;
        break;
      }
    }
    final mark = cur != null
        ? store.chapterMark(widget.meta.id, widget.manga.id, cur.chapter.id)
        : null;
    final finished = mark?.finished ?? false;
    // 跨源已读:话数在共享已读集合里,或当前源有标记。
    final workRead = row.number != null &&
        store.readChaptersFor(widget.manga.title).contains(row.number);
    final read = workRead || mark != null;
    // 下载仅当前源提供时可用(他源专属话不在本详情页下载范围)。
    final downloaded = cur != null &&
        dl.isDownloaded(widget.meta.id, widget.manga.id, cur.chapter.id);
    final prog = cur != null
        ? dl.progressOf(widget.meta.id, widget.manga.id, cur.chapter.id)
        : null;

    Widget status;
    if (finished) {
      status = Icon(Icons.check_circle_rounded, size: 16, color: p.accent);
    } else if (cur != null && mark != null) {
      status = Text(
          '读到 ${mark.page + 1}${mark.total > 0 ? '/${mark.total}' : ''}',
          style: TextStyle(
              color: p.accentSoft, fontSize: 10.5, fontWeight: FontWeight.w700));
    } else if (read) {
      // 他源读过(本源无页码明细)→ 空心勾。
      status =
          Icon(Icons.check_circle_outline_rounded, size: 15, color: p.accentSoft);
    } else {
      status = const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _openMerged(row,
            initialPage: (mark != null && !mark.finished) ? mark.page : 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(context.radius),
            border: Border.all(
                color: finished ? p.accent.withValues(alpha: 0.35) : p.line),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: read ? p.textMuted : p.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5)),
                    if (multi) ...[
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final pv in row.providers)
                            _srcChip(p, pv.meta.name,
                                pv.meta.id == widget.meta.id),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              status,
              const SizedBox(width: 10),
              // 下载状态/按钮(仅当前源提供本话时显示)。
              if (cur != null)
                GestureDetector(
                  onTap: (downloaded || prog != null)
                      ? null
                      : () => dl.enqueue(
                          widget.meta, widget.manga, cur!.chapter, _imgHeaders),
                  child: downloaded
                      ? Icon(Icons.download_done_rounded,
                          size: 17, color: p.accent)
                      : prog != null
                          ? SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                  value: prog > 0 ? prog : null,
                                  strokeWidth: 2,
                                  color: p.accent))
                          : Icon(Icons.download_rounded,
                              size: 17, color: p.textMuted),
                ),
              if (cur != null) const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 18, color: p.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _chapterSlivers(
      AppPalette p, LibraryStore store, DownloadStore dl) {
    final acc = _cover?.primary ?? p.accent;
    // 合并跨源章节(当前源 + 库里同名书的他源;无他源时 = 当前源本身)。
    final merged = _chapters == null ? const <_MergedChapter>[] : _mergedChapters();
    final extra = merged.length - (_chapters?.length ?? 0); // 他源补进来的话数
    final header = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Text(
          _chapters == null
              ? '章节'
              : '章节 · 共 ${merged.length}'
                  '${extra > 0 ? '(+$extra 他源)' : ''}'
                  '${_mergeLoading ? ' · 找其它源中…' : ''}',
          style: TextStyle(
              color: Color.lerp(p.textPrimary, acc, 0.4), // 融入封面主题色
              fontWeight: FontWeight.w700,
              fontSize: 13),
        ),
      ),
    );
    Widget stateBox(Widget child) => SliverToBoxAdapter(
          child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), child: child),
        );

    if (_error != null) {
      return [
        header,
        stateBox(AppErrorView(
          title: '章节加载失败',
          message: '$_error',
          onRetry: _reloadChapters,
          retryLabel: '重新加载章节',
        )),
      ];
    }
    if (_chapters == null) {
      return [
        header,
        stateBox(const Padding(
            padding: EdgeInsets.symmetric(vertical: 26),
            child: Center(child: CircularProgressIndicator()))),
      ];
    }
    // 当前源没解析到章节,但他源合并进来了 → 照样渲染合并列表(别把他源章节丢了)。
    if (merged.isEmpty) {
      return [
        header,
        stateBox(Column(
          children: [
            Text('没解析到章节',
                style: TextStyle(color: p.textPrimary, fontSize: 13)),
            const SizedBox(height: 8),
            SelectableText('id: ${widget.manga.id}\n${widget.manga.url ?? ''}',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textMuted, fontSize: 11)),
            const SizedBox(height: 8),
            Text('把此 id 填入「调试 → ⑦ → 保存详情页 HTML」存下来发我调',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textMuted, fontSize: 11)),
          ],
        )),
      ];
    }
    return [
      header,
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        sliver: SliverList.builder(
          itemCount: merged.length,
          // 每行从右侧滑入 + 淡入,首屏按下标错落(滚动时也「滚到哪滑到哪」)。
          itemBuilder: (ctx, i) => FadeSlideIn(
            dx: 32,
            offset: 0,
            delayMs: (i < 8 ? i : 8) * 22,
            child: _chapterRow(p, store, merged[i], dl),
          ),
        ),
      ),
    ];
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteAnim);
    if (_tintPushed) DetailTint.pop(_tintToken); // 兜底:还在栈里就出栈
    _source.dispose();
    for (final o in _otherSources) {
      o.source.dispose();
    }
    super.dispose();
  }
}

/// 库里同名书某个「他源」的章节表(合并跨源章节列表用)。
class _SrcChapters {
  _SrcChapters(
      this.meta, this.source, this.mangaId, this.title, this.cover, this.chapters);
  final SourceMeta meta;
  final MangaSource source;
  final String mangaId;
  final String title; // 该源自己的书名(打开时进度用它的元数据)
  final String? cover; // 该源自己的封面
  final List<Chapter> chapters;
}

/// 一个源对某话的供给:从哪个源、哪个引擎、打开哪一章。
class _ChapterProvider {
  _ChapterProvider(this.meta, this.source, this.chapter, this.mangaId);
  final SourceMeta meta;
  final MangaSource source;
  final Chapter chapter;
  final String mangaId;
}

/// 合并后的一话:跨源按话数对齐,记录该话由哪些源提供。
class _MergedChapter {
  _MergedChapter(this.number, this.label, this.providers);
  final double? number; // 话数;null = 解析不出(番外等),按当前源原样保留
  final String label; // 展示章名(取首个 provider 的)
  final List<_ChapterProvider> providers; // 提供该话的源(当前源优先在前)
}
