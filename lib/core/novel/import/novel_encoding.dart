import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:charset/charset.dart' as charset;
import 'package:charset_converter/charset_converter.dart';

/// 判定为 UTF-16 所需的单侧 NUL 占比。ASCII 正文接近 1.0,中文正文靠换行和
/// 标点也能过线;真正的 UTF-8 正文一个 NUL 都不该有。
const double _utf16NulRatio = 0.2;

abstract interface class LegacyCharsetDecoder {
  Future<String> decode(String encoding, Uint8List bytes);
}

class PlatformLegacyCharsetDecoder implements LegacyCharsetDecoder {
  const PlatformLegacyCharsetDecoder();

  @override
  Future<String> decode(String encoding, Uint8List bytes) {
    if (encoding != 'gb18030' && encoding != 'big5') {
      throw ArgumentError.value(encoding, 'encoding', 'unsupported charset');
    }
    return CharsetConverter.decode(encoding, bytes);
  }
}

class DecodedNovelText {
  const DecodedNovelText({
    required this.text,
    required this.encoding,
    required this.confidence,
  });

  final String text;
  final String encoding;
  final double confidence;
}

class NovelTextDecoder {
  NovelTextDecoder([LegacyCharsetDecoder? legacyDecoder])
      : _legacyDecoder = legacyDecoder ?? const PlatformLegacyCharsetDecoder();

  final LegacyCharsetDecoder _legacyDecoder;

  Future<DecodedNovelText> decode(
    List<int> input, {
    String? forcedEncoding,
  }) async {
    final bytes = Uint8List.fromList(input);
    if (forcedEncoding != null) {
      return _decodeForced(bytes, _canonicalEncoding(forcedEncoding));
    }

    if (_startsWith(bytes, const [0xef, 0xbb, 0xbf])) {
      return _result(
        utf8.decode(bytes.sublist(3), allowMalformed: false),
        'utf-8',
      );
    }
    if (_startsWith(bytes, const [0xff, 0xfe])) {
      return _result(_decodeUtf16(bytes, true, 2), 'utf-16le');
    }
    if (_startsWith(bytes, const [0xfe, 0xff])) {
      return _result(_decodeUtf16(bytes, false, 2), 'utf-16be');
    }

    // 没有 BOM 的 UTF-16 必须在 UTF-8 之前判:纯 ASCII 正文的 UTF-16 每个字符
    // 都带一个 NUL 补位,而 NUL 本身是合法 UTF-8,严格解码会「成功」,
    // 读者拿到的却是字里夹着空字符的乱码。
    final utf16 = _detectUtf16(bytes);
    if (utf16 != null) {
      return _result(_decodeUtf16(bytes, utf16 == 'utf-16le', 0), utf16);
    }

    try {
      return _result(utf8.decode(bytes, allowMalformed: false), 'utf-8');
    } on FormatException {
      // Continue through scored legacy candidates.
    }

    final candidates = <DecodedNovelText>[];
    await _addPlatformCandidate(candidates, bytes, 'gb18030');
    try {
      candidates.add(_result(charset.gbk.decode(bytes), 'gbk'));
    } on FormatException {
      // The bytes are not valid GBK.
    }
    await _addPlatformCandidate(candidates, bytes, 'big5');

    if (candidates.isEmpty) {
      throw const FormatException('TXT encoding could not be determined');
    }
    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
    return candidates.first;
  }

  Future<DecodedNovelText> _decodeForced(
    Uint8List bytes,
    String encoding,
  ) async {
    switch (encoding) {
      case 'utf-8':
        final offset = _startsWith(bytes, const [0xef, 0xbb, 0xbf]) ? 3 : 0;
        return _result(
          utf8.decode(bytes.sublist(offset), allowMalformed: false),
          encoding,
        );
      case 'utf-16le':
        final offset = _startsWith(bytes, const [0xff, 0xfe]) ? 2 : 0;
        return _result(_decodeUtf16(bytes, true, offset), encoding);
      case 'utf-16be':
        final offset = _startsWith(bytes, const [0xfe, 0xff]) ? 2 : 0;
        return _result(_decodeUtf16(bytes, false, offset), encoding);
      case 'gbk':
        return _result(charset.gbk.decode(bytes), encoding);
      case 'gb18030':
      case 'big5':
        return _result(await _legacyDecoder.decode(encoding, bytes), encoding);
    }
    throw StateError('unreachable encoding: $encoding');
  }

  Future<void> _addPlatformCandidate(
    List<DecodedNovelText> candidates,
    Uint8List bytes,
    String encoding,
  ) async {
    try {
      candidates.add(_result(
        await _legacyDecoder.decode(encoding, bytes),
        encoding,
      ));
    } catch (_) {
      // A platform may not expose every requested legacy charset.
    }
  }

  DecodedNovelText _result(String text, String encoding) {
    return DecodedNovelText(
      text: text,
      encoding: encoding,
      confidence: _plausibility(text, encoding),
    );
  }
}

String _canonicalEncoding(String value) {
  switch (value.trim().toLowerCase().replaceAll('_', '-')) {
    case 'utf8':
    case 'utf-8':
      return 'utf-8';
    case 'utf16le':
    case 'utf-16le':
      return 'utf-16le';
    case 'utf16be':
    case 'utf-16be':
      return 'utf-16be';
    case 'gbk':
    case 'cp936':
      return 'gbk';
    case 'gb18030':
      return 'gb18030';
    case 'big5':
    case 'big-5':
      return 'big5';
    default:
      throw ArgumentError.value(value, 'forcedEncoding', 'unsupported charset');
  }
}

/// 无 BOM 的 UTF-16 探测:看 NUL 落在偶数位还是奇数位。UTF-8 正文里根本不该
/// 出现 NUL,所以「一侧大量 NUL + 另一侧几乎没有」就足够判定,不会误伤中文。
String? _detectUtf16(Uint8List bytes) {
  if (bytes.length < 4 || bytes.length.isOdd) return null;
  var evenNul = 0;
  var oddNul = 0;
  for (var index = 0; index < bytes.length; index += 2) {
    if (bytes[index] == 0) evenNul++;
    if (bytes[index + 1] == 0) oddNul++;
  }
  final threshold = (bytes.length ~/ 2) * _utf16NulRatio;
  if (oddNul > threshold && evenNul * 4 < oddNul) return 'utf-16le';
  if (evenNul > threshold && oddNul * 4 < evenNul) return 'utf-16be';
  return null;
}

String _decodeUtf16(Uint8List bytes, bool littleEndian, int offset) {
  if ((bytes.length - offset).isOdd) {
    throw const FormatException('UTF-16 input has an incomplete code unit');
  }
  final codeUnits = <int>[];
  for (var index = offset; index < bytes.length; index += 2) {
    final first = bytes[index];
    final second = bytes[index + 1];
    codeUnits.add(littleEndian ? first | (second << 8) : (first << 8) | second);
  }
  return String.fromCharCodes(codeUnits);
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

/// 常用简体字粗表(取自字频前五百左右)。判编码用不着完整字表:
/// 解对了正文里六七成的汉字都落在这张表里,解错了命中率不到一成。
const String _commonSimplified =
    '的一是不了在人有我他这个们中来上大为和国地到以说时要就出会可也你对生能而子那得于着下自之年过发后作里用道行所然家种事成方多经么去法学'
    '如都同现当没动面起看定天分还进好小部其些主样理心她本前开但因只从想实日军者意无力它与长把机十民第公此已工使情明性知全三又关点正业外将两高'
    '间由问很最重并物手应战向头文体政美相见被利什二等产或新己制身果加西斯月话合回特代内信表化老给世位次度门任常先海通教儿原东声提立及比员解水名真论处走义'
    '各入几口认条平系气题活尔更别打女变四神总何电数安少报才结反受目太量再感建务做接必场件计管期市直德资命山金指克许统区保至队形社便空决治展马科司五基眼书'
    '非则听白却界达光放强即像难且权思王象完设式色路记南品住告类求据程北边死张该交规万取拉格望觉术领共确传师观清今切院让识候带导争运笑飞风步改收根干造言'
    '联持组每济车亲极林服快办议往元英士证近失转夫令准布始怎呢存未远叫台单影具罗字爱击流备兵连调深商算质团集百需价花党华城石级整府离况亚请技际约示复病息究线似官火'
    '断精满支视消越器容照须九增研写称企八功吗包片史委乎查轻易早曾除农找装广显吧阿李标谈吃图念六引历首医局突专费号尽另周较注语仅考落青随选列武红响虽推势参希古'
    '众构房半节土投案黄河食香倒章卷篇集序楔尾声';

/// 常用繁体字粗表。GB18030 和 Big5 都能把任意双字节还原成
/// 「合法汉字」,光看是不是汉字区分不了两者 —— 得看落在哪一套常用字里。
const String _commonTraditional =
    '的一是不了在人有我他這個們中來上大為和國地到以說時要就出會可也你對生能而子那得於著下自之年過發後作裡用道行所然家種事成方多經麼去法學'
    '如都同現當沒動面起看定天分還進好小部其些主樣理心她本前開但因只從想實日軍者意無力它與長把機十民第公此已工使情明性知全三又關點正業外將兩高'
    '間由問很最重並物手應戰向頭文體政美相見被利什二等產或新己制身果加西斯月話合回特代內信表化老給世位次度門任常先海通教兒原東聲提立及比員解水名真論處走義'
    '各入幾口認條平系氣題活爾更別打女變四神總何電數安少報才結反受目太量再感建務做接必場件計管期市直德資命山金指克許統區保至隊形社便空決治展馬科司五基眼書'
    '非則聽白卻界達光放強即像難且權思王象完設式色路記南品住告類求據程北邊死張該交規萬取拉格望覺術領共確傳師觀清今切院讓識候帶導爭運笑飛風步改收根幹造言'
    '聯持組每濟車親極林服快辦議往元英士證近失轉夫令準布始怎呢存未遠叫台單影具羅字愛擊流備兵連調深商算質團集百需價花黍華城石級整府離況亞請技際約示復病息究線似官火'
    '斷精滿支視消越器容照須九增研寫稱企八功嗎包片史委乎查輕易早曾除農找裝廣顯吧阿李標談吃圖念六引歷首醫局突專費號盡另週較註語僅考落青隨選列武紅響雖推勢參希古'
    '眾構房半節土投案黃河食香倒章卷篇集序楔尾聲';

final Set<int> _simplifiedRunes = _commonSimplified.runes.toSet();
final Set<int> _traditionalRunes = _commonTraditional.runes.toSet();

Set<int> _commonRunesFor(String encoding) =>
    encoding == 'big5' ? _traditionalRunes : _simplifiedRunes;

bool _isCjkIdeograph(int rune) => rune >= 0x4e00 && rune <= 0x9fff;

/// 写小说的人不会用到这些:私有区、扩展 A、希腊/西里尔、制表符 ——
/// 它们出现就意味着拿错了代码页。
bool _isImplausibleRune(int rune) =>
    (rune >= 0xe000 && rune <= 0xf8ff) ||
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x0370 && rune <= 0x052f) ||
    (rune >= 0x2500 && rune <= 0x257f);

bool _isTextPunctuation(int rune) =>
    rune == 0x09 ||
    rune == 0x0a ||
    rune == 0x0d ||
    (rune >= 0x20 && rune <= 0x7e) ||
    (rune >= 0x3000 && rune <= 0x303f) ||
    (rune >= 0xff01 && rune <= 0xff65);

double _plausibility(String text, String encoding) {
  if (text.isEmpty) return 0;
  final common = _commonRunesFor(encoding);
  var replacements = 0;
  var controls = 0;
  var score = 0.0;
  var total = 0;
  for (final rune in text.runes) {
    total++;
    if (rune == 0xfffd || rune == charset.replacementCharacterUnicode) {
      replacements++;
    } else if ((rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d) ||
        (rune >= 0x7f && rune <= 0x9f)) {
      controls++;
    } else if (common.contains(rune)) {
      score += 1;
    } else if (_isTextPunctuation(rune)) {
      score += 0.9;
    } else if (_isImplausibleRune(rune)) {
      // 一分不给。
    } else if (_isCjkIdeograph(rune)) {
      score += 0.45;
    } else {
      score += 0.25;
    }
  }
  final penalty = (replacements * 8 + controls * 4) / total;
  return math.max(0, math.min(1, score / total - penalty)).toDouble();
}
