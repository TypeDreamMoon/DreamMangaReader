import '../../core/novel/models.dart';
import '../../core/novel/novel_source.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../detail/cross_source_sheet.dart';

/// 漫画 / 番剧的换源会话:两者都跑 [MangaSource],搜索接口也一样。
class MangaCrossSourceSession implements CrossSourceSession {
  MangaCrossSourceSession(SourceMeta meta,
      {MangaSource Function(SourceMeta meta) builder = buildSource})
      : _source = builder(meta);

  final MangaSource _source;

  @override
  Future<List<CrossSourceItem>> search(String query) async {
    final page = await _source.getSearch(query, 1);
    return [
      for (final manga in page.items)
        CrossSourceItem(
          id: manga.id,
          title: manga.title,
          cover: manga.cover,
          authors: manga.authors,
          payload: manga,
        ),
    ];
  }

  @override
  void dispose() => _source.dispose();
}

/// 小说的换源会话:走 [NovelSource],模型是 [Novel]。
class NovelCrossSourceSession implements CrossSourceSession {
  NovelCrossSourceSession(SourceMeta meta,
      {NovelSource Function(SourceMeta meta) builder = buildNovelSource})
      : _source = builder(meta);

  final NovelSource _source;

  @override
  Future<List<CrossSourceItem>> search(String query) async {
    final page = await _source.getNovelSearch(query, 1);
    return [
      for (final novel in page.items)
        CrossSourceItem(
          id: novel.id,
          title: novel.title,
          cover: novel.cover,
          authors: novel.authors,
          payload: novel,
        ),
    ];
  }

  @override
  void dispose() => _source.dispose();
}
