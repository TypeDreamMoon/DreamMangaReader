import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/bangumi/bangumi_api.dart';
import '../../core/net/image_cache.dart';

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
    });
    final r = await BangumiApi.search(q);
    if (!mounted) return;
    setState(() {
      _results = r;
      _loading = false;
    });
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
      return const Center(child: CircularProgressIndicator());
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
            Text('换个关键词再试试',
                style: TextStyle(color: p.textMuted, fontSize: 11.5)),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: p.line),
      itemBuilder: (_, i) => _row(p, _results[i]),
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
