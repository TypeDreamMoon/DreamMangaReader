/// 从章节名解析「话数」—— 跨源共享进度 / 合并章节表 / 逐章已读打勾的对齐键。
///
/// 章节 id 跨源不通用,但「话数」通用:A 源「第20话」和 B 源「20.标题」都归到 20。
/// 规则(按优先级):
/// 1) 第 N 话/章/回/集 —— 显式标记,最强信号(也防「3人吃火锅 第12话」这类
///    标题以数字开头的误抓;卷号「第N卷」因标记类不含卷而不匹配);
/// 2) **开头的数字**(可带「第」)——「46.标题」「08 新的开始」「第46 上」这类
///    「序号.标题」格式(多数源如此)。数字后紧跟卷/季/日期单位的不算
///    (第2卷 / 第3季 / 2023年);小数只有后面是结尾/空白/分隔符才认
///    (「12.5 番外」是半话,「12.3年后的重逢」的 .3 是标题正文,取 12);
/// 3) N 话/章/回/集(数字+标记,不在开头);
/// 4) 英文源 Chapter/Ch/Ep/# N;
/// 5) 纯数字章名(「1050」)。
/// 解析不出返回 null(如「番外」「序章」「特别篇」——不参与跨源对齐)。
///
/// 注意:**不要**用脚本源自带的 Chapter.number 兜底对齐——部分源(如 YYDS 的
/// data-index)给的是**列表位置**不是话数,番外/预告会拿位置号冒充话数,
/// 抢占真话数的行并污染跨源共享进度(线上实测过)。
library;

/// 解析话数;失败返回 null。
double? parseChapterNumber(String name) {
  final s = _halfWidth(name).trim();
  if (s.isEmpty) return null;

  // 1) 第 N 话/章/回/集(显式标记,最强)。
  final m1 = RegExp(r'第\s*(\d+(?:\.\d+)?)\s*[话話章回集]').firstMatch(s);
  if (m1 != null) return double.tryParse(m1.group(1)!);

  // 2) 开头的数字(「序号.标题」格式,首选路径)。
  final lead = _leadingNumber(s);
  if (lead != null) return lead;

  // 3) N 话/章/回/集(数字紧跟标记,无「第」,不在开头)。
  final m2 = RegExp(r'(\d+(?:\.\d+)?)\s*[话話章回集]').firstMatch(s);
  if (m2 != null) return double.tryParse(m2.group(1)!);

  // 4) 英文源:chapter/episode/chap/ch/ep/# N(词边界防止 punch5 之类误命中)。
  final m3 = RegExp(
    r'(?:\b(?:chapter|episode|chap|ch|ep)\b|#)\s*\.?\s*(\d+(?:\.\d+)?)',
    caseSensitive: false,
  ).firstMatch(s);
  if (m3 != null) return double.tryParse(m3.group(1)!);

  return null;
}

/// 数字后紧跟这些单位 → 不是话数(卷号/篇章部季/日期/时长)。
const List<String> _notChapterUnits = [
  '卷', '巻', '册', '冊', '部', '季', '年', '月', '日', '周', '天', // 单字
  '小时', '个月', // 多字时长(「24小时营业」「3个月后」不是话数)
];

/// 小数点后面是这些(或结尾/空白/话章标记)才把小数当半话,
/// 否则点是「序号.标题」的分隔。
const String _fracSeps = ' \t.-_—·、::()()【】[]话話章回集';

/// 开头的数字(可带「第」前缀)→ 话数;不是编号开头返回 null。
double? _leadingNumber(String s) {
  final m = RegExp(r'^(第?)\s*(\d+)').firstMatch(s);
  if (m == null) return null;
  final hasDi = m.group(1)!.isNotEmpty;
  var numText = m.group(2)!;
  var end = m.end;
  // 试着吃掉 .5 小数:仅当小数后是结尾/空白/分隔/话章标记才认(「12.5 番外」「12.5话」);
  // 否则视为「序号.标题」的分隔点(「46.是勇者…」「12.3年后…」都取整数)。
  final fm = RegExp(r'^\.(\d+)').firstMatch(s.substring(end));
  if (fm != null) {
    final fracEnd = end + fm.end;
    final after = fracEnd < s.length ? s[fracEnd] : '';
    if (after.isEmpty || _fracSeps.contains(after)) {
      numText = '$numText.${fm.group(1)!}';
      end = fracEnd;
    }
  }
  // 数字后**紧贴**卷/季/日期单位 → 不是话数(第2卷 / 2023年 / 100天后 / 24小时)。
  // 裸序号后隔了空格的是「序号 标题」分隔,标题首字撞单位字不拒(「08 月光下的少女」=第8话);
  // 只有带「第」前缀时才跨空格看单位(mangadex 的「第 2 卷」)。
  final tail = s.substring(end);
  final rest = hasDi ? tail.trimLeft() : tail;
  for (final u in _notChapterUnits) {
    if (rest.startsWith(u)) return null;
  }
  return double.tryParse(numText);
}

/// 全角数字/点 → 半角(第１２．５話 → 第12.5話)。
String _halfWidth(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0xff10 && r <= 0xff19) {
      b.writeCharCode(r - 0xfee0); // ０-９ → 0-9
    } else if (r == 0xff0e) {
      b.writeCharCode(0x2e); // ． → .
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}
