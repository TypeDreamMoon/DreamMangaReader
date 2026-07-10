import 'dart:async';

import 'models.dart';
import 'source.dart' show MangaSource;
import 'source_registry.dart';
import 'title_match.dart' show sameWork;

/// 在给定的一批源里**并发**搜 [query],**第一个 `sameWork` 命中立即返回**——
/// 不等最慢的源(其余在途搜索自然结束,引擎照常释放)。
/// [allErrored]=所有源都抛错(区分「真没搜到」与「全源失败」——后者不该再触发翻译回退)。
///
/// 详情页相关推荐点开、书架「为你推荐」把候选解析成可读的源漫画,共用这一套。
Future<({({SourceMeta meta, Manga manga})? match, bool allErrored})> findFirstWork(
    List<SourceMeta> metas, String query) {
  if (metas.isEmpty) return Future.value((match: null, allErrored: false));
  final done =
      Completer<({({SourceMeta meta, Manga manga})? match, bool allErrored})>();
  var pending = metas.length;
  var okCount = 0; // 成功返回(未抛错)的源数
  for (final meta in metas) {
    () async {
      // buildSource 也放进 try:某个源脚本坏了只跳过它,不连累其余源。
      MangaSource? src;
      try {
        src = buildSource(meta);
        final r = await src.getSearch(query, 1);
        okCount++;
        if (!done.isCompleted) {
          for (final m in r.items) {
            if (sameWork(m.title, query)) {
              done.complete((match: (meta: meta, manga: m), allErrored: false));
              break;
            }
          }
        }
      } catch (_) {
      } finally {
        try {
          src?.dispose(); // dispose 抛错也不能吞掉 pending 递减,否则调用方永远挂起
        } catch (_) {}
        if (--pending == 0 && !done.isCompleted) {
          done.complete((match: null, allErrored: okCount == 0));
        }
      }
    }();
  }
  return done.future;
}
