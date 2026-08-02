import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:dream_manga_reader/core/novel/import/novel_encoding.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeLegacyDecoder implements LegacyCharsetDecoder {
  FakeLegacyDecoder({this.values = const {}, this.failByDefault = true});

  final Map<String, String> values;
  final bool failByDefault;
  final List<String> calls = [];

  @override
  Future<String> decode(String encoding, Uint8List bytes) async {
    calls.add(encoding);
    final value = values[encoding];
    if (value != null) return value;
    if (failByDefault) throw const FormatException('unsupported fixture');
    return '';
  }
}

void main() {
  test('BOM and strict UTF-8 win before legacy decoding', () async {
    final legacy = FakeLegacyDecoder();
    final decoder = NovelTextDecoder(legacy);

    final bom = await decoder.decode([0xef, 0xbb, 0xbf, 0x61]);
    final utf8Result = await decoder.decode(utf8.encode('中文'));

    expect(bom.text, 'a');
    expect(bom.encoding, 'utf-8');
    expect(utf8Result.text, '中文');
    expect(utf8Result.encoding, 'utf-8');
    expect(legacy.calls, isEmpty);
  });

  test('UTF-16 BOM is decoded before legacy candidates', () async {
    final decoder = NovelTextDecoder(FakeLegacyDecoder());

    final littleEndian = await decoder.decode([
      0xff,
      0xfe,
      0x2d,
      0x4e,
      0x87,
      0x65,
    ]);
    final bigEndian = await decoder.decode([
      0xfe,
      0xff,
      0x4e,
      0x2d,
      0x65,
      0x87,
    ]);

    expect(littleEndian.text, '中文');
    expect(littleEndian.encoding, 'utf-16le');
    expect(bigEndian.text, '中文');
    expect(bigEndian.encoding, 'utf-16be');
  });

  test('manual legacy encoding overrides detection', () async {
    final legacy = FakeLegacyDecoder(values: {'gb18030': '第一章 开始'});
    final decoder = NovelTextDecoder(legacy);

    final result = await decoder.decode(
      [0x81],
      forcedEncoding: 'GB18030',
    );

    expect(result.text, '第一章 开始');
    expect(result.encoding, 'gb18030');
    expect(legacy.calls, ['gb18030']);
  });

  test('pure Dart GBK is available when the platform decoder fails', () async {
    final decoder = NovelTextDecoder(FakeLegacyDecoder());
    final bytes = gbk.encode('第一章 开始');

    final result = await decoder.decode(bytes);

    expect(result.text, '第一章 开始');
    expect(result.encoding, 'gbk');
  });

  test('legacy detection penalizes replacements and control characters',
      () async {
    final legacy = FakeLegacyDecoder(values: {
      'gb18030': '正文\u{fffd}\u{0001}\u{0002}',
      'big5': '第一章 正常正文',
    });
    final decoder = NovelTextDecoder(legacy);

    final result = await decoder.decode([0x81]);

    expect(result.text, '第一章 正常正文');
    expect(result.encoding, 'big5');
    expect(result.confidence, greaterThan(0.5));
  });

  test('unsupported forced encoding is rejected', () async {
    final decoder = NovelTextDecoder(FakeLegacyDecoder());

    expect(
      () => decoder.decode([0x61], forcedEncoding: 'shift-jis'),
      throwsArgumentError,
    );
  });
}
