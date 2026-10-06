import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import 'chapter_order.dart';

/// 一个源提供的整张章节表(详情页的当前源,或库里同名书的他源)。
/// 构造时就把顺序归一([orderedChapters]),详情页列表与阅读器上一话/下一话共用它。
class ChapterSource {
  ChapterSource(this.meta, this.source, this.mangaId, List<Chapter> chapters)
      : chapters = orderedChapters(chapters);

  final SourceMeta meta;
  final MangaSource source;
  final String mangaId; // 该源自己的书 id
  final List<Chapter> chapters;
}

/// 某一话的一个供给:由哪个源提供、对应它表里的哪一章。
class ChapterProvider {
  const ChapterProvider(this.meta, this.chapter);

  final SourceMeta meta;
  final Chapter chapter;
}

/// 合并后的一话:跨源按话数对齐,记录该话由哪些源提供。
class MergedChapter {
  MergedChapter(this.number, this.label, this.providers);

  final double? number; // 话数;null = 解析不出(序章/番外等),按当前源原样保留
  final String label; // 展示章名(取首个 provider 的)
  final List<ChapterProvider> providers; // 提供该话的源(当前源优先在前)
}

/// 把 [current] + [others] 的章节合并成详情页那张列表。
///
/// - **顺序 = 当前源自己的章节顺序**,不按解析出的话数重排:分季重编号的目录
///   (「第01话…第85话 / 第三季第1话… / 第四季1话… / 第163话…」)只有源自己排得对,
///   按话数排会把几季交错搅在一起,无号章还会被甩到表尾。详见 [orderedChapters]。
/// - 当前源章节**全保留**(含 上/下 拆章、无号章),不因同话数被折叠;
/// - 他源命中当前源已有的话数 → 记为该话的「提供源」;
/// - 他源独有的话数 → 作为补充章插进来(见 [_insertExtras])。
List<MergedChapter> mergeChapters(
    ChapterSource current, List<ChapterSource> others) {
  final rows = <MergedChapter>[];
  final byNumber = <double, List<MergedChapter>>{}; // 挂他源 provider 用

  for (final c in current.chapters) {
    final n = chapterNumberOf(c);
    final row = MergedChapter(n, c.name, [ChapterProvider(current.meta, c)]);
    rows.add(row);
    if (n != null) (byNumber[n] ??= []).add(row);
  }

  final extraByNumber = <double, MergedChapter>{}; // 他源独有的话数
  for (final os in others) {
    for (final c in os.chapters) {
      final n = chapterNumberOf(c);
      if (n == null) continue; // 他源无号章无法对齐,忽略
      final prov = ChapterProvider(os.meta, c);
      final curRows = byNumber[n];
      if (curRows != null) {
        // 当前源已有该话(可能上/下多行)→ 只挂到第一行,避免重复挂。
        final row = curRows.first;
        if (!row.providers.any((pv) => pv.meta.id == os.meta.id)) {
          row.providers.add(prov);
        }
        continue;
      }
      final extra = extraByNumber[n];
      if (extra == null) {
        extraByNumber[n] = MergedChapter(n, c.name, [prov]);
      } else if (!extra.providers.any((pv) => pv.meta.id == os.meta.id)) {
        extra.providers.add(prov);
      }
    }
  }
  if (extraByNumber.isEmpty) return rows;
  return _insertExtras(rows, extraByNumber.values.toList());
}

/// 把他源独有的「补充话」插回当前源的列表:每话跟在**话数比它小的最后一话**之后
/// (当前源没有更小的 → 排到最前)。当前源更新慢时,他源的新话自然落到表尾;
/// 当前源一话都没解析出来时,整串补充话按话数升序自成一表。
List<MergedChapter> _insertExtras(
    List<MergedChapter> rows, List<MergedChapter> extras) {
  // 无号章(序章 / 番外 / 完结篇)跟着**前一话**走:补充话插到它们之后,
  // 免得他源的新话把表尾的「番外」顶开、或者挤到「序章」前面去。
  final settle = List<int>.filled(rows.length + 1, rows.length - 1);
  for (var i = rows.length - 1; i >= 0; i--) {
    settle[i] = rows[i].number == null ? settle[i + 1] : i - 1;
  }

  // 当前源各行与补充话按话数一起升序走一遍:走到某个补充话时,到此为止见过的
  // 最大行号就是它的锚点(当前源话数可能不单调 —— 分季重编号 —— 所以取最大)。
  final marks = <({double number, int row, int extra})>[
    for (var i = 0; i < rows.length; i++)
      if (rows[i].number != null) (number: rows[i].number!, row: i, extra: -1),
    for (var i = 0; i < extras.length; i++)
      (number: extras[i].number!, row: -1, extra: i),
  ]..sort((left, right) => left.number.compareTo(right.number));

  // 当前源一话都没解析出话数时,没有任何锚点可挂:整串补充话按话数升序排到**表最前**。
  // 不能走 settle —— 它的兜底值是 rows.length-1(那是给「锚在某有号章之后、后面
  // 只剩无号章」用的),会把补充话甩到表尾,正好和本函数文档说的「排到最前」相反。
  final anchorable = rows.any((r) => r.number != null);

  final after = <int, List<MergedChapter>>{}; // 行下标 → 跟在它后面的补充话
  var anchor = -1; // -1 = 还没遇到当前源的行 → 插到表最前
  for (final m in marks) {
    if (m.extra < 0) {
      if (m.row > anchor) anchor = m.row;
    } else {
      (after[anchorable ? settle[anchor + 1] : -1] ??= [])
          .add(extras[m.extra]);
    }
  }

  final out = <MergedChapter>[...?after[-1]];
  for (var i = 0; i < rows.length; i++) {
    out.add(rows[i]);
    final add = after[i];
    if (add != null) out.addAll(add);
  }
  return out;
}
