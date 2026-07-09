import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/transitions.dart';
import '../library/manga_cover.dart';
import 'anime_player_page.dart';

/// 番剧详情:封面 + 简介 + 分集网格。点某集 → [AnimePlayerPage] 播放。
/// 番剧沿用漫画契约:getMangaDetail(简介/封面)、getChapters(=分集)。
class AnimeDetailPage extends StatefulWidget {
  const AnimeDetailPage({super.key, required this.meta, required this.anime});

  final SourceMeta meta;
  final Manga anime; // 列表卡带来的 id/title/cover

  @override
  State<AnimeDetailPage> createState() => _AnimeDetailPageState();
}

class _AnimeDetailPageState extends State<AnimeDetailPage> {
  late final MangaSource _source = buildSource(widget.meta);
  Manga? _detail;
  List<Chapter> _episodes = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final id = widget.anime.id;
      final detail = await _source.getMangaDetail(id);
      final eps = await _source.getChapters(id);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _episodes = eps.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _play(int index) => Navigator.of(context).push(appRoute(AnimePlayerPage(
        meta: widget.meta,
        animeId: widget.anime.id,
        animeTitle: (_detail?.title.isNotEmpty ?? false)
            ? _detail!.title
            : widget.anime.title,
        episodes: _episodes,
        index: index,
      )));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final title = (_detail?.title.isNotEmpty ?? false)
        ? _detail!.title
        : widget.anime.title;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      ),
      body: _error != null
          ? _errorView(p)
          : AppScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _header(p, title),
                const SizedBox(height: 20),
                AppSectionHeading('分集', fontSize: 18),
                const SizedBox(height: 12),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_episodes.isEmpty)
                  const EmptyState(
                    title: '没有分集',
                    padding: EdgeInsets.symmetric(vertical: 30, horizontal: 24),
                  )
                else
                  _episodeGrid(p),
              ],
            ),
    );
  }

  Widget _header(AppPalette p, String title) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: MangaCover(
              manga: _detail ?? widget.anime,
              headers: imageHeadersOf(widget.meta),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.25)),
                const SizedBox(height: 8),
                Text(widget.meta.name,
                    style: TextStyle(color: p.accentSoft, fontSize: 12)),
                const SizedBox(height: 10),
                if ((_detail?.description ?? '').isNotEmpty)
                  Text(_detail!.description!,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: p.textMuted, fontSize: 12.5, height: 1.5)),
              ],
            ),
          ),
        ],
      );

  Widget _episodeGrid(AppPalette p) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < _episodes.length; i++)
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 54),
              child: AppCard(
                onTap: () => _play(i),
                radius: context.radius,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Text(
                  _epLabel(_episodes[i], i),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      );

  // 集标签:优先数字集号,否则用名字(截断)。
  String _epLabel(Chapter c, int i) {
    final n = c.number;
    if (n != null) {
      return n == n.roundToDouble() ? '${n.toInt()}' : '$n';
    }
    final name = c.name.trim();
    return name.isEmpty ? '${i + 1}' : name;
  }

  Widget _errorView(AppPalette p) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 40, color: p.textMuted),
              const SizedBox(height: 12),
              Text('加载失败',
                  style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              SelectableText(_error ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textMuted, fontSize: 12)),
              const SizedBox(height: 14),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
}
