import '../source/title_match.dart' show normalizeTitle;
import 'translator.dart';

/// 带**翻译回退**的通用搜索:先用原文搜,搜不到就依次翻成 简 / 繁 / 英 / 日 再搜,
/// 取**第一个有结果**的(并附上所用译名);都搜不到才返回空。全 App 各处搜索共用这一套。
///
/// [enabled]=false(用户在设置里关掉)时只搜原文,不翻译。翻译服务商未配置 / 翻译失败
/// 都静默降级为原文结果。
class TranslatedSearch {
  TranslatedSearch._();

  /// [search]:「用某个词搜」的闭包(返回结果列表,空列表=没搜到)。
  /// 返回:命中的结果 + 所用译名([via]=null 表示用的是原文)。
  static Future<({List<T> results, String? via})> run<T>(
    String query, {
    required bool enabled,
    required List<TranslateProvider> providers,
    required LlmConfig llm,
    required Future<List<T>> Function(String q) search,
  }) async {
    final first = await search(query);
    if (first.isNotEmpty || !enabled || query.trim().isEmpty) {
      return (results: first, via: null);
    }
    // 按用户设的服务商优先级依次尝试(失败降级下一个)。
    final tr = Translator.chain(providers, llm: llm);
    // 译名与原文(或已试过的)归一相同则跳过,不白搜。
    final tried = <String>{normalizeTitle(query)};
    for (final lang in TranslateLang.values) {
      String t;
      try {
        t = (await tr.translate(query, lang)).trim();
      } catch (_) {
        continue;
      }
      if (t.isEmpty || !tried.add(normalizeTitle(t))) continue;
      final r = await search(t);
      if (r.isNotEmpty) return (results: r, via: t);
    }
    return (results: first, via: null); // 都没搜到
  }

  /// 把 [query] 翻成 简 / 繁 / 英 / 日,与原文归一去重后返回**译名列表**(不含原文)。
  /// 给需要「先搜原文、后逐个译名」的自定义增量流程复用(如详情页逐源章节合并):
  /// 只翻一次、各处共享,原文命中的地方就不必再搜译名。翻译没配好 / 失败 → 返回空列表。
  static Future<List<String>> variants(
    String query, {
    required List<TranslateProvider> providers,
    required LlmConfig llm,
  }) async {
    if (query.trim().isEmpty) return const [];
    final tr = Translator.chain(providers, llm: llm);
    final tried = <String>{normalizeTitle(query)};
    final out = <String>[];
    for (final lang in TranslateLang.values) {
      try {
        final t = (await tr.translate(query, lang)).trim();
        if (t.isNotEmpty && tried.add(normalizeTitle(t))) out.add(t);
      } catch (_) {/* 某语言失败:跳过 */}
    }
    return out;
  }
}
