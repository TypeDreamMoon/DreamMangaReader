import 'chinese_fold.dart';

/// 源返回的作者字段没有统一格式:有的塞一整串「A / B」「A,B」「A、B」,有的带
/// 「著」「绘」「原作」这类职务后缀,繁简也各写各的。搜索同作者作品必须先把两边
/// 折成同一把尺子,否则「尾田荣一郎」搜不到「尾田榮一郎 著」。
class AuthorMatch {
  AuthorMatch._();

  static final RegExp _separators = RegExp(r'[/／,，、;；|｜]+');
  static final RegExp _roleSuffix = RegExp(
    r'[\s(（\[【]*(著|作|绘|畫|画|原作|作画|作畫|漫画|漫畫|小说|小說|编|編)'
    r'[)）\]】]*$',
  );
  static final RegExp _noise = RegExp(r'[\s·・\.。,，、:：;；\-—_~～"”“'
      r"'’‘]+");

  /// 把一个作者字段拆成若干作者名(已去空白,保留原文大小写)。
  static List<String> split(String raw) => raw
      .split(_separators)
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);

  /// 拆分并展开一组作者字段。
  static List<String> expand(Iterable<String> authors) => [
        for (final author in authors) ...split(author),
      ];

  /// 归一化用于比较的作者名:折繁为简、去职务后缀与标点空白、统一小写。
  static String normalize(String value) {
    final folded = ChineseFold.fold(value.trim()).toLowerCase();
    final withoutRole = folded.replaceAll(_roleSuffix, '');
    final stripped = withoutRole.replaceAll(_noise, '');
    return stripped.isEmpty ? folded.replaceAll(_noise, '') : stripped;
  }

  /// [authors] 里有没有人就是 [query]。完全相等优先,其次允许一方包含另一方
  /// (例如「CLAMP」对「CLAMP(大川七濑)」)。
  static bool matches(Iterable<String> authors, String query) {
    final target = normalize(query);
    if (target.isEmpty) return false;
    for (final author in expand(authors)) {
      final value = normalize(author);
      if (value.isEmpty) continue;
      if (value == target) return true;
      if (value.length >= 2 && target.length >= 2 &&
          (value.contains(target) || target.contains(value))) {
        return true;
      }
    }
    return false;
  }
}
