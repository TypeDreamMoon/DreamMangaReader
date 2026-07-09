import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/title_match.dart';
import '../../core/translate/translator.dart';
import '../../ui/ui.dart';

/// 跨源搜索同名漫画(详情页「换源」用):在**其它**已启用的漫画源里搜当前书名。
///
/// **跨语言**:除了原文,还用翻译功能把书名翻成简体 / 繁体 / 英文,各语种都拿去搜一轮
/// —— 这样中文源的书也能在 MangaDex 等英文源里找到同名版本。原文先搜、先出结果,
/// 译名到了再补搜(去重),翻译不可用(未配置/失败)时静默降级为只用原文。
///
/// 归一化(对任一语种变体)同名的置顶、标「同名」。选中返回该源的 [pick](meta+manga)。
/// 各源/各变体并发搜第 1 页;单源失败只跳过它。构建的源在 dispose 全部释放。
typedef CrossSourcePick = ({SourceMeta meta, Manga manga});

class CrossSourceSheet extends StatefulWidget {
  const CrossSourceSheet({
    super.key,
    required this.title,
    required this.currentSourceId,
  });

  /// 初始查询词(通常 = 当前漫画标题)。
  final String title;

  /// 当前所在源 id —— 换源要换到**别的**源,故从候选里排除它。
  final String currentSourceId;

  @override
  State<CrossSourceSheet> createState() => _CrossSourceSheetState();
}

class _CrossSourceSheetState extends State<CrossSourceSheet> {
  late final TextEditingController _c =
      TextEditingController(text: widget.title);

  // 候选源(其它已启用的漫画源),各自持一个引擎,dispose 时释放。
  final List<({SourceMeta meta, MangaSource source})> _sources = [];
  final List<CrossSourcePick> _results = [];

  int _pending = 0; // 在途搜索任务数(源 × 变体);0 且未在翻译 = 本轮结束
  bool _translating = false; // 正在翻译书名(译名变体还没到齐)
  bool _searched = false;
  int _gen = 0; // 会话代际:换词重搜后丢弃在途旧结果

  final Set<String> _seenKeys = {}; // 结果去重:'sourceId:mangaId'
  final Set<String> _searchedQueries = {}; // 已搜过的查询(归一)去重,免重复搜同一词
  final Set<String> _variantNorms = {}; // 各语种变体的归一标题,判「同名」用
  final List<String> _variantQueries = []; // 实际搜过的原始查询词(原文 + 译名),用于展示

  @override
  void initState() {
    super.initState();
    final store = LibraryScope.read(context);
    for (final s in registeredSources) {
      if (s.kind == 'manga' &&
          s.id != widget.currentSourceId &&
          store.isSourceEnabled(s.id)) {
        _sources.add((meta: s, source: buildSource(s)));
      }
    }
    _run();
  }

  @override
  void dispose() {
    _c.dispose();
    for (final s in _sources) {
      s.source.dispose();
    }
    super.dispose();
  }

  bool get _busy => _pending > 0 || _translating;

  void _run() {
    final q = _c.text.trim();
    // 先自增代际:作废任何在途旧搜索/翻译(尤其清空查询后重搜)。
    final gen = ++_gen;
    final active = q.isNotEmpty && _sources.isNotEmpty;
    setState(() {
      _results.clear();
      _seenKeys.clear();
      _searchedQueries.clear();
      _variantNorms.clear();
      _variantQueries.clear();
      _searched = true;
      _pending = 0;
      _translating = false;
    });
    if (!active) return;
    _searchVariant(gen, q); // 原文立即搜
    // 翻译补搜(找跨语言的同名版本)受设置「搜索翻译回退」开关控制,默认开。
    if (LibraryScope.read(context).translateSearch) {
      _translateAndSearch(gen, q); // 并发翻成简/繁/英/日,到一个补搜一轮
    }
  }

  /// 用一个查询词 [query] 把所有候选源各搜一轮(同一归一查询只搜一次)。
  void _searchVariant(int gen, String query) {
    if (gen != _gen || _sources.isEmpty) return;
    final norm = normalizeTitle(query);
    final key = norm.isEmpty ? query.trim().toLowerCase() : norm;
    if (key.isEmpty || !_searchedQueries.add(key)) return; // 该(归一)查询已搜过
    if (norm.isNotEmpty) _variantNorms.add(norm);
    setState(() {
      _variantQueries.add(query.trim());
      _pending += _sources.length;
    });
    for (final s in _sources) {
      _searchOne(gen, s.meta, s.source, query);
    }
  }

  /// 把书名翻成简/繁/英,每翻好一个就拿去补搜一轮。翻译不可用时静默(只留原文结果)。
  Future<void> _translateAndSearch(int gen, String q) async {
    final store = LibraryScope.read(context);
    // 按用户设的服务商优先级链式翻译(失败自动降级下一个)。
    final tr =
        Translator.chain(store.translateProviderOrder, llm: store.translateLlm);
    setState(() => _translating = true);
    try {
      await Future.wait(TranslateLang.values.map((lang) async {
        try {
          final out = await tr.translate(q, lang);
          if (!mounted || gen != _gen) return;
          _searchVariant(gen, out); // 新语种变体再搜一轮(内部按归一查询去重)
        } catch (_) {
          // 单个目标语翻译失败:跳过,不影响其它语种/原文
        }
      }));
    } finally {
      if (mounted && gen == _gen) setState(() => _translating = false);
    }
  }

  Future<void> _searchOne(
      int gen, SourceMeta meta, MangaSource source, String q) async {
    List<Manga> items = const [];
    try {
      items = (await source.getSearch(q, 1)).items;
    } catch (_) {
      // 某源失败(限流/无匹配)→ 跳过它,不打断其它源/变体
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      for (final m in items) {
        if (!_seenKeys.add('${meta.id}:${m.id}')) continue; // 跨变体/源去重
        _results.add((meta: meta, manga: m));
      }
      // 同名(归一标题命中任一语种变体)置顶,便于一眼挑到正确的书;稳定排序保持到达序。
      _results.sort((a, b) =>
          (_isSameName(a.manga.title) ? 0 : 1) -
          (_isSameName(b.manga.title) ? 0 : 1));
      _pending--;
    });
  }

  /// 结果标题归一后是否命中任一语种变体 → 视为「同名」。
  bool _isSameName(String title) {
    final n = normalizeTitle(title);
    return n.isNotEmpty && _variantNorms.contains(n);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 展示译名变体(原文之外的),让用户知道正在跨语言找。
    final extra = _variantQueries.skip(1).toList();
    // 外壳(圆角/限高/键盘避让/标题+关闭)由 showAppSheet 提供。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _c,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _run(),
          style: TextStyle(color: p.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: '在其它源搜索书名(自动翻译简/繁/英)',
            hintStyle: TextStyle(color: p.textMuted),
            suffixIcon: IconButton(
              onPressed: _run,
              icon: const Icon(Icons.search_rounded, size: 20),
              color: p.accent,
            ),
          ),
        ),
        if (extra.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2, right: 2),
            child: Row(
              children: [
                Icon(Icons.translate_rounded, size: 13, color: p.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('译名同搜:${extra.join(' · ')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Expanded(child: _body(p)),
      ],
    );
  }

  Widget _body(AppPalette p) {
    if (_sources.isEmpty) {
      return _empty(p, Icons.source_rounded, '没有其它可用源',
          '再启用一个漫画源,就能在源之间换着看');
    }
    if (_busy && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searched && _results.isEmpty && !_busy) {
      return _empty(p, Icons.search_off_rounded, '其它源没搜到同名漫画',
          '换个关键词再试试(或到设置换个翻译服务商)');
    }
    return AppScrollView.separated(
      // 底部一行细进度:还在搜/翻译时提示。
      itemCount: _results.length + (_busy ? 1 : 0),
      separatorBuilder: (_, __) => Divider(height: 1, color: p.line),
      itemBuilder: (_, i) {
        if (i >= _results.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(_translating ? '翻译并搜索其它源…' : '仍在搜索其它源…',
                  style: TextStyle(color: p.textMuted, fontSize: 12)),
            ),
          );
        }
        return _row(p, _results[i]);
      },
    );
  }

  Widget _empty(AppPalette p, IconData icon, String title, String hint) =>
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: p.textMuted),
            const SizedBox(height: 10),
            Text(title, style: TextStyle(color: p.textMuted, fontSize: 13)),
            const SizedBox(height: 4),
            Text(hint,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textMuted, fontSize: 11.5)),
          ],
        ),
      );

  Widget _row(AppPalette p, CrossSourcePick r) {
    final m = r.manga;
    final exact = _isSameName(m.title);
    final cover = m.cover;
    return InkWell(
      onTap: () => Navigator.of(context).pop(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 44,
                height: 62,
                child: (cover == null || cover.isEmpty)
                    ? ColoredBox(color: p.background)
                    : CachedNetworkImage(
                        cacheManager: appImageCache,
                        imageUrl: cover,
                        httpHeaders: imageHeadersOf(r.meta),
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) =>
                            ColoredBox(color: p.background),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // 源角标
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: p.surface,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: p.line),
                        ),
                        child: Text(r.meta.name,
                            style:
                                TextStyle(color: p.textMuted, fontSize: 10.5)),
                      ),
                      if (exact) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: p.accent.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text('同名',
                              style: TextStyle(
                                  color: p.accent,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                      if (m.authors.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(m.authors.join(' / '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: p.textMuted, fontSize: 11)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
