import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dream_manga_reader/core/novel/import/novel_encoding.dart';
import 'package:dream_manga_reader/core/novel/import/txt_novel_importer.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:flutter_test/flutter_test.dart';

class StubLegacyDecoder implements LegacyCharsetDecoder {
  const StubLegacyDecoder(this.text);

  final String text;

  @override
  Future<String> decode(String encoding, Uint8List bytes) async => text;
}

void main() {
  late Directory sandbox;
  late Directory supportDirectory;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('txt-importer-test-');
    supportDirectory = Directory('${sandbox.path}${Platform.pathSeparator}app');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('preview decodes, hashes and parses without writing app support',
      () async {
    final rawText = '梦书\r\n作者：作者甲\r\n\r\n第一章 开始\r\n正文一。';
    final bytes = utf8.encode(rawText);
    final source = File('${sandbox.path}${Platform.pathSeparator}梦书.txt');
    await source.writeAsBytes(bytes);
    final importer = TxtNovelImporter(
      applicationSupportDirectory: () async => supportDirectory,
    );

    final preview = await importer.preview(source);

    expect(preview, isA<ImportedNovelPreview>());
    expect(preview.sha256, sha256.convert(bytes).toString());
    expect(preview.origin, NovelOrigin.localTxt);
    expect(preview.encoding, 'utf-8');
    expect(preview.title, '梦书');
    expect(preview.authors, ['作者甲']);
    expect(preview.chapters.single.title, '第一章 开始');
    expect(preview.normalizedText, isNot(contains('\r')));
    expect(await supportDirectory.exists(), isFalse);
  });

  test('preview forwards forced encoding to the injected decoder', () async {
    final source = File('${sandbox.path}${Platform.pathSeparator}legacy.txt');
    await source.writeAsBytes([0x81]);
    final importer = TxtNovelImporter(
      applicationSupportDirectory: () async => supportDirectory,
      decoder: NovelTextDecoder(
        const StubLegacyDecoder('旧书\n\n第一章 开始\n正文。'),
      ),
    );

    final preview = await importer.preview(
      source,
      forcedEncoding: 'gb18030',
    );

    expect(preview.encoding, 'gb18030');
    expect(preview.title, '旧书');
  });

  test('importPreview atomically installs normalized text and index JSON',
      () async {
    final source = File('${sandbox.path}${Platform.pathSeparator}book.txt');
    await source.writeAsString('''书名
作者：作者乙
第一卷 起点

第一章 开始
正文一。

第二章 继续
正文二。''');
    final importer = TxtNovelImporter(
      applicationSupportDirectory: () async => supportDirectory,
    );
    final preview = await importer.preview(source);

    final installed = await importer.importPreview(preview);

    expect(
      installed.path,
      '${supportDirectory.path}${Platform.pathSeparator}novels'
      '${Platform.pathSeparator}local${Platform.pathSeparator}${preview.sha256}',
    );
    final content = File(
      '${installed.path}${Platform.pathSeparator}content.txt',
    );
    final indexFile = File(
      '${installed.path}${Platform.pathSeparator}index.json',
    );
    expect(await content.readAsString(), preview.normalizedText);
    final index =
        jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
    expect(index['schema'], 1);
    expect(index['sha256'], preview.sha256);
    expect(index['encoding'], 'utf-8');
    expect(index['title'], '书名');
    expect(index['authors'], ['作者乙']);
    final chapters = index['chapters'] as List<dynamic>;
    expect(chapters.length, 2);
    expect((chapters.first as Map<String, dynamic>)['volumeTitle'], '第一卷 起点');
    expect((chapters.last as Map<String, dynamic>)['endOffset'],
        utf8.encode(preview.normalizedText).length);

    final novels = installed.parent.parent;
    expect(
      novels.listSync().where((entry) => entry.path.contains('.tmp-')),
      isEmpty,
    );
    expect((await importer.importPreview(preview)).path, installed.path);
  });
}
