import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/cover_hero.dart';
import '../common/animations.dart';
import '../common/transitions.dart';
import '../detail/detail_page.dart';
import '../library/manga_cover.dart';

/// 站点特化「浏览」页:把某个源的板块(排行榜/连载/完结/漫画大全…)做成 tab,
/// 每个板块分页拉取漫画卡片。板块由源脚本声明([MangaSource.sections]),
/// 无板块的源会显示占位。后续新源实现 sections 即可复用此页。
class BrowsePage extends StatefulWidget {
  const BrowsePage({super.key, required this.meta, this.sourceBuilder = buildSource});

  final SourceMeta meta;

  /// 测试注入用;正式代码走 [buildSource]。
  final MangaSource Function(SourceMeta meta) sourceBuilder;

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  late final MangaSource _source = widget.sourceBuilder(widget.meta);
  late final List<SourceSection> _sections = _source.sections;

  int _sel = 0;
  final List<Manga> _items = [];
  final Set<String> _seen = {};
  int _page = 1;
  bool _loading = false;
  bool _end = false;
  String? _error;

  /// 请求代际:每次换板块自增。在途的旧请求回来时代际已经变了 —— 结果直接丢弃,
  /// 而 `_loading` 由换板块那一下就地复位,新一轮不会被旧请求的「加载中」挡在门外
  /// (这正是「在途切板块 → 永久转圈」的成因)。
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    if (_sections.isNotEmpty) _loadMore();
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _gen++; // 在途请求就此作废
      _items.clear();
      _seen.clear();
      _page = 1;
      _end = false;
      _error = null;
      _loading = false; // 旧请求不再有权复位它,这里就地放行新一轮
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _end || _sections.isEmpty) return;
    final gen = _gen;
    setState(() => _loading = true);
    final sec = _sections[_sel];
    final wantPage = _page;
    Paged<Manga>? res;
    Object? failure;
    try {
      res = await _source.getSection(sec.id, wantPage);
    } catch (e) {
      failure = e;
    }
    // 只认当前代际的结果。旧代际的成功/失败都不写状态 —— 包括 `_loading`:
    // 那时新一轮多半已经在跑,复位它反而会让滚动到底触发重复请求。
    if (!mounted || gen != _gen) return;
    setState(() {
      _loading = false;
      if (failure != null) {
        _error = '$failure';
        _end = true;
        return;
      }
      final page = res!;
      var added = 0;
      for (final m in page.items) {
        if (_seen.add(m.id)) {
          _items.add(m);
          added++;
        }
      }
      _page = wantPage + 1;
      // 无新增(单页板块如最新/排行,翻页返回同一批)或源说没下一页 → 停止。
      if (added == 0 || !page.hasNext) _end = true;
    });
  }

  void _select(int i) {
    if (i == _sel) return;
    setState(() => _sel = i);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(context.l10n.browse_titleName(widget.meta.name),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      ),
      body: _sections.isEmpty
          ? EmptyState(title: context.l10n.browse_noSections)
          : Column(
              children: [
                _tabs(),
                Expanded(child: _grid(p)),
              ],
            ),
    );
  }

  Widget _tabs() => SizedBox(
        height: 48,
        child: AppScrollView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: _sections.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final sel = i == _sel;
            return AppFilterChip(
              label: _sections[i].name,
              selected: sel,
              onTap: () => _select(i),
            );
          },
        ),
      );

  Widget _grid(AppPalette p) {
    if (_items.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(context.l10n.browse_loadFailedDetail('$_error'),
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textMuted, fontSize: 12)),
          ),
        );
      }
      return EmptyState(title: context.l10n.browse_sectionEmpty);
    }
    return SmoothScroll(
      builder: (sc) => NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (!_loading &&
              !_end &&
              n.metrics.pixels >= n.metrics.maxScrollExtent - 600) {
            _loadMore();
          }
          return false;
        },
        child: GridView.builder(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 168,
            crossAxisSpacing: 12,
            mainAxisSpacing: 14,
            // 贴合 3/4 封面 + 标题行,减少封面下方大片留白。
            childAspectRatio: 0.64,
          ),
          itemCount: _items.length,
          itemBuilder: (_, i) => _card(p, _items[i], i),
        ),
      ),
    );
  }

  Widget _card(AppPalette p, Manga m, int i) {
    final tag = coverHeroTag(CoverHeroScope.browseSection,
            sourceId: widget.meta.id, itemId: m.id, index: i);
    return FlyInUp(
      seed: m.id,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: MangaCover(
              manga: m,
              headers: imageHeadersOf(widget.meta),
              heroTag: tag,
              onTap: () => pushPage(context, 
                  DetailPage(manga: m, meta: widget.meta, heroTag: tag)),
            ),
          ),
          const SizedBox(height: 6),
          Text(m.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 12,
                  height: 1.25,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
