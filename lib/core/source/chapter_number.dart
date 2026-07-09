/// 从章节名解析「话数」—— 跨源共享进度 / 合并章节表 / 逐章已读打勾的对齐键。
///
/// 章节 id 跨源不通用,但「话数」通用:A 源「第20话」和 B 源「Chapter 20」都归到 20。
/// 支持:第N话/章/回/集、N话、Chapter/Ch/Ep/Episode/# N、纯数字,含 .5 番外(第10.5话)。
/// 优先「话/章/回/集」上的数字(排除卷号 第N卷 / Vol.N)。解析不出返回 null
/// (如「番外」「序章」「特别篇」——这类不参与跨源对齐)。
library;

/// 解析话数;失败返回 null。
double? parseChapterNumber(String name) {
  final s = _halfWidth(name).trim();
  if (s.isEmpty) return null;

  // 1) 第 N 话/章/回/集(最强信号;卷号「第N卷」因 [话話章回集] 不含卷而不匹配)。
  final m1 = RegExp(r'第\s*(\d+(?:\.\d+)?)\s*[话話章回集]').firstMatch(s);
  if (m1 != null) return double.tryParse(m1.group(1)!);

  // 2) N 话/章/回/集(数字紧跟标记,无「第」)。
  final m2 = RegExp(r'(\d+(?:\.\d+)?)\s*[话話章回集]').firstMatch(s);
  if (m2 != null) return double.tryParse(m2.group(1)!);

  // 3) 英文源:chapter/episode/chap/ch/ep/# N(词边界防止 punch5 之类误命中)。
  final m3 = RegExp(
    r'(?:\b(?:chapter|episode|chap|ch|ep)\b|#)\s*\.?\s*(\d+(?:\.\d+)?)',
    caseSensitive: false,
  ).firstMatch(s);
  if (m3 != null) return double.tryParse(m3.group(1)!);

  // 4) 整个名字就是个数字(很多源的章名直接是「1050」/「1050.5」)。
  final m4 = RegExp(r'^(\d+(?:\.\d+)?)$').firstMatch(s);
  if (m4 != null) return double.tryParse(m4.group(1)!);

  return null;
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
