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
