import 'models.dart';
import 'source.dart' show MangaSource;
import 'source_registry.dart';
import 'title_match.dart' show sameWork;

/// 在给定的一批源里**并发**搜 [query],返回第一个 `sameWork` 命中(找到即用,不等其余源)。
/// [allErrored]=所有源都抛错(区分「真没搜到」与「全源失败」——后者不该再触发翻译回退)。
///
/// 详情页相关推荐点开、书架「为你推荐」把候选解析成可读的源漫画,共用这一套。
Future<({({SourceMeta meta, Manga manga})? match, bool allErrored})> findFirstWork(
    List<SourceMeta> metas, String query) async {
  ({SourceMeta meta, Manga manga})? found;
  var okCount = 0; // 成功返回(未抛错)的源数
  await Future.wait(metas.map((meta) async {
    if (found != null) return;
    // buildSource 也放进 try:某个源脚本坏了只跳过它,不连累其余源(否则 Future.wait
    // 会整体抛出,详情页 spinner 卡死 / 推荐批次直接判失败)。
    MangaSource? src;
    try {
      src = buildSource(meta);
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
      src?.dispose();
    }
  }));
  return (match: found, allErrored: okCount == 0 && metas.isNotEmpty);
}
