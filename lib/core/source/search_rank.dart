import 'chinese_fold.dart';
import 'title_match.dart' show sameWork;

/// 搜索结果标题与查询词的相关度层级(混合搜索的插排依据):
///   3 = 同名(容繁简/全半角/标点差异)
///   2 = 同作品(容副标题,`sameWork`)
///   1 = 标题与查询互相包含(前缀/系列名等)
///   0 = 其它(源的关键词模糊召回)
int searchRelevance(String title, String query) {
  if (query.isEmpty) return 0;
  final dt = ChineseFold.dedupKey(title);
  final dq = ChineseFold.dedupKey(query);
  if (dt.isEmpty || dq.isEmpty) return 0;
  if (dt == dq) return 3;
  if (sameWork(title, query)) return 2;
  if (dt.contains(dq) || dq.contains(dt)) return 1;
  return 0;
}
