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
      confidence: _plausibility(text),
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

double _plausibility(String text) {
  if (text.isEmpty) return 0;
  var replacements = 0;
  var controls = 0;
  var printable = 0;
  var total = 0;
  for (final rune in text.runes) {
    total++;
    if (rune == 0xfffd || rune == charset.replacementCharacterUnicode) {
      replacements++;
    } else if ((rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d) ||
        (rune >= 0x7f && rune <= 0x9f)) {
      controls++;
    } else {
      printable++;
    }
  }
  final penalty = (replacements * 8 + controls * 4) / total;
  return math.max(0, math.min(1, printable / total - penalty)).toDouble();
}
