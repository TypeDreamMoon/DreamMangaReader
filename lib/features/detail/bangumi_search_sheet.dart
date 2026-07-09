import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/bangumi/bangumi_api.dart';
import '../../core/net/image_cache.dart';
import '../../core/source/title_match.dart';
import '../../core/translate/translator.dart';

/// 手动搜索 Bangumi 条目并选择。返回选中的 [BangumiCandidate](取消返回 null)。
/// 自动匹配不准/没匹配到时用;搜不到会给出提示。
class BangumiSearchSheet extends StatefulWidget {
  const BangumiSearchSheet({super.key, required this.initialQuery});

  final String initialQuery;

  @override
  State<BangumiSearchSheet> createState() => _BangumiSearchSheetState();
}

class _BangumiSearchSheetState extends State<BangumiSearchSheet> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initialQuery);
  bool _loading = false;
  bool _searched = false;
  bool _translating = false; // 原文搜不到 → 翻译后重搜阶段
  String? _viaTranslate; // 用哪个译名搜到的(展示提示);null=原文
  List<BangumiCandidate> _results = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _c.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _searched = true;
      _translating = false;
      _viaTranslate = null;
    });
    final r = await BangumiApi.search(q);
    if (!mounted) return;
    if (r.isNotEmpty) {
      setState(() {
        _results = r;
        _loading = false;
      });
      return;
    }
    // 原文搜不到 → 翻译一下再搜(简/繁/英),都没有才显示搜不到。
    setState(() => _translating = true);
    final t = await _searchViaTranslation(q);
    if (!mounted) return;
    setState(() {
      _results = t.results;
      _viaTranslate = t.query;
      _loading = false;
      _translating = false;
    });
  }

  /// 把 [q] 翻成简/繁/英逐个去 Bangumi 搜,返回**第一个有结果**的(附所用译名)。
  /// 翻译未配置/都没搜到 → 返回空。译名与原文(或已试过的)归一相同则跳过,不白搜。
  Future<({List<BangumiCandidate> results, String? query})> _searchViaTranslation(
      String q) async {
    const empty = (results: <BangumiCandidate>[], query: null);
    final Translator tr;
    try {
      final store = LibraryScope.read(context);
      tr = Translator.create(store.translateProvider, llm: store.translateLlm);
    } catch (_) {
      return empty; // 翻译没配好 → 保持搜不到
    }
    final tried = <String>{normalizeTitle(q)};
    for (final lang in TranslateLang.values) {
      String t;
      try {
        t = (await tr.translate(q, lang)).trim();
      } catch (_) {
        continue;
      }
      if (!mounted) return empty;
      if (t.isEmpty || !tried.add(normalizeTitle(t))) continue;
      try {
        final rr = await BangumiApi.search(t);
        if (rr.isNotEmpty) return (results: rr, query: t);
      } catch (_) {}
    }
    return empty;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 外壳(圆角/SafeArea/限高/键盘避让/标题「搜索 Bangumi」+ 关闭)由 showAppSheet 提供。
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
            hintText: '输入条目名',
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
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (_translating) ...[
              const SizedBox(height: 12),
              Text('原文没搜到,翻译后再搜…',
                  style: TextStyle(color: p.textMuted, fontSize: 12)),
            ],
          ],
        ),
      );
    }
    if (_searched && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 40, color: p.textMuted),
            const SizedBox(height: 10),
            Text('没有搜到相关条目',
                style: TextStyle(color: p.textMuted, fontSize: 13)),
            const SizedBox(height: 4),
            Text('原文和译名都没搜到 · 换个关键词再试试',
                style: TextStyle(color: p.textMuted, fontSize: 11.5)),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_viaTranslate != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 2, right: 2),
            child: Row(
              children: [
                Icon(Icons.translate_rounded, size: 13, color: p.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('原文没搜到,用译名「$_viaTranslate」搜到',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
            itemCount: _results.length,
            separatorBuilder: (_, __) => Divider(height: 1, color: p.line),
            itemBuilder: (_, i) => _row(p, _results[i]),
          ),
        ),
      ],
    );
  }

  Widget _row(AppPalette p, BangumiCandidate c) => InkWell(
        onTap: () => Navigator.of(context).pop(c),
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
                  child: c.image.isEmpty
                      ? ColoredBox(color: p.background)
                      : CachedNetworkImage(
                          cacheManager: appImageCache,
                          imageUrl: c.image,
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
                    Text(c.display,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700)),
                    if (c.nameCn.isNotEmpty && c.name != c.nameCn)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(color: p.textMuted, fontSize: 11)),
                      ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (c.score > 0) ...[
                          Icon(Icons.star_rounded,
                              size: 13, color: p.bangumi),
                          const SizedBox(width: 2),
                          Text(c.score.toStringAsFixed(1),
                              style:
                                  TextStyle(color: p.textMuted, fontSize: 11)),
                          const SizedBox(width: 8),
                        ],
                        if (c.date.isNotEmpty)
                          Text(c.date,
                              style:
                                  TextStyle(color: p.textMuted, fontSize: 11)),
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
