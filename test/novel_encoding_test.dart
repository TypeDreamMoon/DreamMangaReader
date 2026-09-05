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

  test('BOM-less UTF-16 is detected before strict UTF-8 succeeds', () async {
    final legacy = FakeLegacyDecoder();
    final decoder = NovelTextDecoder(legacy);
    const plain = 'Chapter One\nHello there.\n';
    final littleEndian = <int>[
      for (final unit in plain.codeUnits) ...[unit & 0xff, unit >> 8],
    ];
    final bigEndian = <int>[
      for (final unit in plain.codeUnits) ...[unit >> 8, unit & 0xff],
    ];

    final le = await decoder.decode(littleEndian);
    final be = await decoder.decode(bigEndian);

    expect(le.encoding, 'utf-16le');
    expect(le.text, plain);
    expect(be.encoding, 'utf-16be');
    expect(be.text, plain);
    expect(legacy.calls, isEmpty);
  });

  test('plain UTF-8 prose is never mistaken for UTF-16', () async {
    final decoder = NovelTextDecoder(FakeLegacyDecoder());

    final result = await decoder.decode(
      utf8.encode('第一章 开始\n正文一。\nplain ascii tail\n'),
    );

    expect(result.encoding, 'utf-8');
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

  test('a real Big5 sample outranks its GB18030 mis-decoding', () async {
    // 真实 Big5 字节:'第一章 開始 / 他們在這裡說話...'。GB18030 一样能把它们
    // 「解码成功」,只是解出来一堆私用区和生僻字 —— 置信度必须能看出差别。
    const big5Bytes = <int>[
      0xb2, 0xc4, 0xa4, 0x40, 0xb3, 0xb9, 0x20, 0xb6, 0x7d, 0xa9, 0x6c, 0x0a,
      0xa5, 0x4c, 0xad, 0xcc, 0xa6, 0x62, 0xb3, 0x6f, 0xb8, 0xcc, 0xbb, 0xa1,
      0xb8, 0xdc, 0xa1, 0x41, 0xae, 0xc9, 0xb6, 0xa1, 0xb9, 0x4c, 0xb1, 0x6f,
      0xab, 0xdc, 0xa7, 0xd6, 0xa1, 0x43, 0x0a, 0xb3, 0x6f, 0xad, 0xd3, 0xb0,
      0xea, 0xae, 0x61, 0xaa, 0xba, 0xa4, 0x48, 0xad, 0xcc, 0xb3, 0xa3, 0xb7,
      0x7c, 0xa8, 0xd3, 0xac, 0xdd, 0xae, 0xd1, 0xa1, 0x43, 0x0a,
    ];
    const big5Text = '\u{7b2c}\u{4e00}\u{7ae0} \u{958b}\u{59cb}\n\u{4ed6}\u{5011}\u{5728}\u{9019}\u{88e1}\u{8aaa}\u{8a71}\u{ff0c}\u{6642}\u{9593}\u{904e}\u{5f97}\u{5f88}\u{5feb}\u{3002}\n\u{9019}\u{500b}\u{570b}\u{5bb6}\u{7684}\u{4eba}\u{5011}\u{90fd}\u{6703}\u{4f86}\u{770b}\u{66f8}\u{3002}\n';
    const gbMojibake = '\u{6750}\u{e5e6}\u{5f7b} \u{79e8}\u{fe4d}\n\u{e652}\u{e145}\u{e6c8}\u{7842}\u{67d1}\u{5f27}\u{6760}\u{e4c7}\u{e1a0}\u{4e01}\u{7b41}\u{7714}\u{e099}\u{435}\u{e4c9}\n\u{7842}\u{e14c}\u{74e3}\u{7522}\u{e019}\u{e5ee}\u{e145}\u{5e38}\u{7a66}\u{3113}\u{e0f8}\u{e1a8}\u{e4c9}\n';
    final legacy = FakeLegacyDecoder(values: {
      'gb18030': gbMojibake,
      'big5': big5Text,
    });
    final decoder = NovelTextDecoder(legacy);

    final result = await decoder.decode(big5Bytes);

    expect(result.encoding, 'big5');
    expect(result.text, big5Text);
    expect(result.confidence, greaterThan(0.8));
  });

  test('unsupported forced encoding is rejected', () async {
    final decoder = NovelTextDecoder(FakeLegacyDecoder());

    expect(
      () => decoder.decode([0x61], forcedEncoding: 'shift-jis'),
      throwsArgumentError,
    );
  });
}
