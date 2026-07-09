/// 跨源同名匹配:标题归一化 + 同名判断。
///
/// 多源同名去重 / 详情页换源 / 跨源同名搜索共用。归一化策略(保守、确定性):
/// 全角→半角 + 转小写,再剔除所有标点/符号/空白/控制字符。只保留文字与数字 →
/// 「Re:从零」「Re:从零」「[连载]Re 从零」归一后相同。
library;

// 剔除标点 / 符号 / 分隔符(空白)/ 控制格式字符,保留所有文字与数字。
// 用「排除法」而非「保留特定文字集」:后者会误删韩文谚文、西里尔、带音标拉丁、
// CJK 扩展 A 等 → 把不同的书归一成同一 key(假去重 + 「N源」角标虚高)。unicode
// 属性类(\p{P}\p{S}\p{Z}\p{C})覆盖全角/半角标点,对所有语种都稳。
final RegExp _stripRe = RegExp(r'[\p{P}\p{S}\p{Z}\p{C}]+', unicode: true);

/// 归一化标题:大小写 / 全角半角 / 标点空白差异都抹平。
String normalizeTitle(String s) {
  final buf = StringBuffer();
  for (final r in s.trim().toLowerCase().runes) {
    if (r == 0x3000) {
      buf.writeCharCode(0x20); // 全角空格 → 半角(随后剔除)
    } else if (r >= 0xff01 && r <= 0xff5e) {
      buf.writeCharCode(r - 0xfee0); // 全角 ASCII(！～)→ 半角
    } else {
      buf.writeCharCode(r);
    }
  }
  return buf.toString().replaceAll(_stripRe, '');
}

/// 两个标题归一后是否相同(空标题永不视为同名)。
bool sameTitle(String a, String b) {
  final na = normalizeTitle(a);
  return na.isNotEmpty && na == normalizeTitle(b);
}

// 成对括号(含全角/书名号/引号)——用于剥掉 [连载]【全彩】(完结) 之类装饰副标题。
final RegExp _bracketRe =
    RegExp(r'[\[\(（【「『][^\]\)）】」』]*[\]\)）】」』]');

/// 作品核心标题:先剥掉成对括号内的装饰副标题([连载] 等),再归一。
/// 剥没了(整标题都在括号里)就退回整标题归一。跨源把同一作品归到一起用。
String coreTitle(String s) {
  final core = normalizeTitle(s.replaceAll(_bracketRe, ' '));
  return core.isEmpty ? normalizeTitle(s) : core;
}

/// 两个 coreTitle 归一 key 是否**同一作品**——容繁简 + 残留副标题。
/// 规则:短串/长串长度比 ≥0.7,且短串去重字符命中长串比例 ≥0.7。
/// 繁简变体多数字相同(高命中)→ 归一;续作/外传(长度差大或重叠低)→ 不归。
bool sameCoreKey(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final shorter = a.length <= b.length ? a : b;
  final longer = a.length <= b.length ? b : a;
  if (shorter.length / longer.length < 0.7) return false; // 长度差太多 → 不同作
  final longSet = longer.split('').toSet();
  final shortDistinct = shorter.split('').toSet();
  var hit = 0;
  for (final ch in shortDistinct) {
    if (longSet.contains(ch)) hit++;
  }
  return hit / shortDistinct.length >= 0.7;
}

/// 两个标题是否同一作品(容繁简 + 副标题)。
bool sameWork(String a, String b) => sameCoreKey(coreTitle(a), coreTitle(b));
