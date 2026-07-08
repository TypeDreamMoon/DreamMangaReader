import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/title_match.dart';

/// 跨源搜索同名漫画(详情页「换源」用):在**其它**已启用的漫画源里搜当前书名,
/// 归一化同名的置顶、标「同名」。选中返回该源的 [pick](meta+manga),调用方据此换源。
///
/// 各源并发搜第 1 页、先到先显示;单源失败只跳过它。构建的源在 dispose 全部释放。
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
  int _pending = 0; // 仍在搜的源数(0 = 本轮结束)
  bool _searched = false;
  int _gen = 0; // 会话代际:换词重搜后丢弃在途旧结果

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

  void _run() {
    final q = _c.text.trim();
    // 先自增代际:作废任何在途旧搜索(尤其清空查询后重搜,别让旧结果继续追加)。
    final gen = ++_gen;
    final active = q.isNotEmpty && _sources.isNotEmpty;
    setState(() {
      _results.clear();
      _searched = true;
      _pending = active ? _sources.length : 0;
    });
    if (!active) return;
    for (final s in _sources) {
      _searchOne(gen, s.meta, s.source, q);
    }
  }

  Future<void> _searchOne(
      int gen, SourceMeta meta, MangaSource source, String q) async {
    List<Manga> items = const [];
    try {
      final r = await source.getSearch(q, 1);
      items = r.items;
    } catch (_) {
      // 某源失败(限流/无匹配)→ 跳过它,不打断其它源
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      for (final m in items) {
        _results.add((meta: meta, manga: m));
      }
      // 同名(归一化标题相同)置顶,便于一眼挑到正确的书;稳定排序,同档保持到达序。
      _results.sort((a, b) {
        final ea = sameTitle(a.manga.title, widget.title) ? 0 : 1;
        final eb = sameTitle(b.manga.title, widget.title) ? 0 : 1;
        return ea - eb;
      });
      _pending--;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
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
            hintText: '在其它源搜索书名',
            hintStyle: TextStyle(color: p.textMuted),
            suffixIcon: IconButton(
              onPressed: _run,
              icon: const Icon(Icons.search_rounded, size: 20),
              color: p.accent,
            ),
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
    if (_pending > 0 && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searched && _results.isEmpty) {
      return _empty(p, Icons.search_off_rounded, '其它源没搜到同名漫画', '换个关键词再试试');
    }
    return ListView.separated(
      // 顶部一行细进度:还有源在搜时提示「仍在搜索…」。
      itemCount: _results.length + (_pending > 0 ? 1 : 0),
      separatorBuilder: (_, __) => Divider(height: 1, color: p.line),
      itemBuilder: (_, i) {
        if (i >= _results.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text('仍在搜索其它源…',
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
            Text(hint, style: TextStyle(color: p.textMuted, fontSize: 11.5)),
          ],
        ),
      );

  Widget _row(AppPalette p, CrossSourcePick r) {
    final m = r.manga;
    final exact = sameTitle(m.title, widget.title);
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
