import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/log/app_log.dart';
import '../../core/source/author_match.dart';
import '../../core/source/chinese_fold.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/cover_hero.dart';
import '../library/manga_cover.dart';

/// 一条搜索结果:记住它来自哪个源(打开详情要用那个源的引擎)。
typedef AuthorWork = ({Manga manga, SourceMeta meta, bool authorConfirmed});

/// 「同作者作品」。详情页点作者名进来:先在**当前源**按作者名搜,再并发补其它
/// 同类型的已启用源。源的搜索接口只吃一个关键词,拿回来的是模糊召回,所以这里
/// 再按作者字段过一遍 —— 作者字段真的对上的排前面并打勾,其余作为「可能相关」保留。
class AuthorWorksPage extends StatefulWidget {
  const AuthorWorksPage({
    super.key,
    required this.author,
    required this.meta,
    required this.kind,
    required this.onOpen,
    this.excludeMangaId,
    this.sourceBuilder = buildSource,
  });

  final String author;
  final SourceMeta meta;

  /// 只在同类型的源里搜:`manga` / `anime`。
  final String kind;
  /// 打开某部作品。[heroTag] 是封面的 Hero 标记 —— 详情页要用同一个值,
  /// 封面才会从这张卡飞过去(见 [coverHeroTag])。
  final void Function(BuildContext context, SourceMeta meta, Manga manga,
      Object? heroTag) onOpen;
  final String? excludeMangaId;
  final MangaSource Function(SourceMeta meta) sourceBuilder;

  @override
  State<AuthorWorksPage> createState() => _AuthorWorksPageState();
}

class _AuthorWorksPageState extends State<AuthorWorksPage> {
  final List<AuthorWork> _works = [];
  final Set<String> _seen = {};
  int _pending = 0;
  bool _started = false;
  bool _allFailed = false;
  int _failures = 0;
  int _generation = 0;

  bool get _loading => _pending > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  List<SourceMeta> _targets() {
    final store = LibraryScope.read(context);
    return [
      widget.meta,
      for (final source in registeredSources)
        if (source.kind == widget.kind &&
            source.id != widget.meta.id &&
            store.isSourceEnabled(source.id))
          source,
    ];
  }

  Future<void> _search() {
    final generation = ++_generation;
    final targets = _targets();
    setState(() {
      _started = true;
      _works.clear();
      _seen.clear();
      _failures = 0;
      _allFailed = false;
      _pending = targets.length;
    });
    AppLog.i.info(
      LogCat.search,
      '搜索作者「${widget.author}」· ${targets.length} 个源',
    );
    return Future.wait([
      for (final meta in targets) _searchOne(meta, generation),
    ]);
  }

  Future<void> _searchOne(SourceMeta meta, int generation) async {
    MangaSource? source;
    try {
      source = widget.sourceBuilder(meta);
      final page = await source.getSearch(widget.author, 1);
      if (!mounted || generation != _generation) return;
      _ingest(meta, page.items);
    } catch (_) {
      if (mounted && generation == _generation) _failures++;
    } finally {
      try {
        source?.dispose();
      } catch (_) {}
      if (mounted && generation == _generation) {
        setState(() {
          _pending--;
          _allFailed = _pending == 0 && _works.isEmpty && _failures > 0;
        });
      }
    }
  }

  void _ingest(SourceMeta meta, List<Manga> items) {
    for (final manga in items) {
      if (meta.id == widget.meta.id && manga.id == widget.excludeMangaId) {
        continue;
      }
      final key = '${meta.id}\n${ChineseFold.dedupKey(manga.title)}';
      if (!_seen.add(key)) continue;
      final confirmed = AuthorMatch.matches(manga.authors, widget.author);
      final entry = (manga: manga, meta: meta, authorConfirmed: confirmed);
      // 作者字段真的对上的排前面,其余按到达顺序跟在后面。
      var index = _works.length;
      if (confirmed) {
        while (index > 0 && !_works[index - 1].authorConfirmed) {
          index--;
        }
      }
      _works.insert(index, entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final confirmed = _works.where((work) => work.authorConfirmed).length;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(
          context.l10n.author_worksTitle(widget.author),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 18),
              child: Center(
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: !_started || (_loading && _works.isEmpty)
          ? const Center(child: CircularProgressIndicator())
          : _works.isEmpty
              ? EmptyState(
                  key: const Key('author-works-empty'),
                  title: _allFailed
                      ? context.l10n.detail_otherSourcesAllFailed
                      : context.l10n.author_worksEmpty(widget.author),
                )
              : AppScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10, left: 2),
                      child: Text(
                        context.l10n.author_worksCount(_works.length, confirmed),
                        style: TextStyle(color: p.textMuted, fontSize: 12),
                      ),
                    ),
                    LayoutBuilder(
                      builder: (context, constraints) => GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 172,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 14,
                          childAspectRatio: .58,
                        ),
                        itemCount: _works.length,
                        itemBuilder: (context, index) => _card(_works[index]),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _card(AuthorWork work) {
    final p = context.palette;
    final tag = coverHeroTag(
      CoverHeroScope.authorWorks,
      sourceId: work.meta.id,
      itemId: work.manga.id,
    );
    // 整张卡可点(封面 + 书名),不是只有封面那块。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onOpen(context, work.meta, work.manga, tag),
      child: _cardBody(work, p, tag),
    );
  }

  Widget _cardBody(AuthorWork work, AppPalette p, Object heroTag) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: MangaCover(
            manga: work.manga,
            headers: imageHeadersOf(work.meta),
            heroTag: heroTag,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          work.manga.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: p.textPrimary,
            fontSize: 12,
            height: 1.25,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            if (work.authorConfirmed) ...[
              Icon(Icons.verified_rounded, size: 12, color: p.accent),
              const SizedBox(width: 3),
            ],
            Expanded(
              child: Text(
                work.meta.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textMuted, fontSize: 10.5),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
