/// 跨源同名匹配:标题归一化 + 同名判断。
///
/// 多源同名去重 / 详情页换源 / 跨源同名搜索共用。归一化策略(保守、确定性):
/// 全角→半角 + 转小写,再剔除所有非「字母/数字/汉字/假名」字符(空白、括号、
/// 各种标点/装饰)。只保留核心文字 → 「Re:从零」「Re：从零」「[连载]Re 从零」归一后相同。
library;

// 只保留:数字 / a-z(已转小写)/ 平假名·片假名 / CJK 统一表意 / CJK 兼容表意。
final RegExp _stripRe =
    RegExp('[^0-9a-z぀-ヿ一-鿿豈-﫿]+');

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
