import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dream_manga_reader/core/novel/import/epub_novel_importer.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late Directory supportDirectory;
  late EpubNovelImporter importer;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('epub-importer-test-');
    supportDirectory = Directory('${sandbox.path}${Platform.pathSeparator}app');
    importer = EpubNovelImporter(
      applicationSupportDirectory: () async => supportDirectory,
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('EPUB 2 follows spine and NCX instead of filename order', () async {
    final bytes = epub2Fixture();

    final preview = await importer.previewBytes(bytes);

    expect(preview, isA<ImportedNovelPreview>());
    expect(preview.sha256, sha256.convert(bytes).toString());
    expect(preview.origin, NovelOrigin.localEpub);
    expect(preview.title, '测试 EPUB 2');
    expect(preview.authors, ['作者甲']);
    expect(preview.language, 'zh-CN');
    expect(preview.chapters.map((chapter) => chapter.title), ['序章', '第一章']);
    expect(preview.chapters.map((chapter) => chapter.id), ['c1', 'c2']);
    expect(preview.hasCover, true);
    expect(await supportDirectory.exists(), isFalse);
  });

  test('preview protects hashed source and resource bytes from mutation',
      () async {
    final preview = await importer.previewBytes(epub2Fixture());

    expect(
      () => preview.originalBytes[0] = 0,
      throwsUnsupportedError,
    );
    expect(
      () => preview.resources.values.first[0] = 0,
      throwsUnsupportedError,
    );
  });

  test('EPUB 3 import keeps ruby and safe resources but removes scripts',
      () async {
    final bytes = epub3Fixture();

    final book = await importer.importBytes(bytes);
    final html = await book.readChapter('c1');

    expect(html, contains('<ruby>'));
    expect(html, contains('<rt>'));
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('onclick=')));
    expect(
      await File(
        '${book.directory.path}${Platform.pathSeparator}resources'
        '${Platform.pathSeparator}OEBPS${Platform.pathSeparator}Images'
        '${Platform.pathSeparator}cover.png',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${book.directory.path}${Platform.pathSeparator}resources'
        '${Platform.pathSeparator}OEBPS${Platform.pathSeparator}Fonts'
        '${Platform.pathSeparator}book.otf',
      ).readAsBytes(),
      [0, 1, 2, 3],
    );
    expect(
      await File(
        '${book.directory.path}${Platform.pathSeparator}original.epub',
      ).readAsBytes(),
      bytes,
    );
    final index = jsonDecode(
      await File(
        '${book.directory.path}${Platform.pathSeparator}index.json',
      ).readAsString(),
    ) as Map<String, dynamic>;
    expect(index['schema'], 1);
    expect(index['language'], 'ja');
    expect((index['chapters'] as List).length, 2);
    expect((await importer.importBytes(bytes)).directory.path,
        book.directory.path);
  });

  test('accepts EPUB 2 cover metadata that uses href instead of manifest id',
      () async {
    final preview = await importer.previewBytes(
      epub2Fixture(coverMetaUsesHref: true),
    );

    expect(preview.hasCover, isTrue);
    expect(preview.chapters.length, 2);
  });

  test('rejects fixed-layout and missing readable spine', () async {
    expect(
      () => importer.previewBytes(epub3Fixture(fixedLayout: true)),
      throwsFormatException,
    );
    expect(
      () => importer.previewBytes(epub2Fixture(includeSpine: false)),
      throwsFormatException,
    );
  });

  test('preflight rejects a zip bomb before eager CRC verification', () async {
    final archive = Archive()
      ..addFile(ArchiveFile(
        'OEBPS/bomb.xhtml',
        2 * 1024 * 1024,
        Uint8List(2 * 1024 * 1024),
      ));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    _zeroZipCrc(bytes);

    expect(
      () => importer.previewBytes(bytes),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains('compression ratio'),
      )),
    );
  });
}

Uint8List epub2Fixture({
  bool includeSpine = true,
  bool coverMetaUsesHref = false,
}) {
  final opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">book-2</dc:identifier>
    <dc:title>测试 EPUB 2</dc:title>
    <dc:creator>作者甲</dc:creator>
    <dc:language>zh-CN</dc:language>
    <meta name="cover" content="${coverMetaUsesHref ? 'cover.png' : 'cover-image'}" />
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml" />
    <item id="chapter2" href="Text/chapter2.xhtml" media-type="application/xhtml+xml" />
    <item id="chapter1" href="Text/chapter1.xhtml" media-type="application/xhtml+xml" />
    <item id="cover-image" href="Images/cover.png" media-type="image/png" />
    <item id="font" href="Fonts/book.otf" media-type="font/otf" />
  </manifest>
  ${includeSpine ? '<spine toc="ncx"><itemref idref="chapter1" /><itemref idref="chapter2" /></spine>' : ''}
</package>''';
  final toc = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="book-2" /></head>
  <docTitle><text>测试 EPUB 2</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>序章</text></navLabel><content src="Text/chapter1.xhtml" /></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>第一章</text></navLabel><content src="Text/chapter2.xhtml" /></navPoint>
  </navMap>
</ncx>''';
  return _epubArchive({
    'OEBPS/Text/chapter2.xhtml': _xhtml('第二页'),
    'OEBPS/Text/chapter1.xhtml': _xhtml('第一页'),
    'META-INF/container.xml': _container,
    'OEBPS/content.opf': opf,
    'OEBPS/toc.ncx': toc,
    'OEBPS/Images/cover.png': _onePixelPng,
    'OEBPS/Fonts/book.otf': [0, 1, 2, 3],
  });
}

Uint8List epub3Fixture({bool fixedLayout = false}) {
  final opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">book-3</dc:identifier>
    <dc:title>测试 EPUB 3</dc:title>
    <dc:creator>作者乙</dc:creator>
    <dc:language>ja</dc:language>
    ${fixedLayout ? '<meta property="rendition:layout">pre-paginated</meta>' : ''}
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav" />
    <item id="chapter1" href="Text/chapter1.xhtml" media-type="application/xhtml+xml" />
    <item id="chapter2" href="Text/chapter2.xhtml" media-type="application/xhtml+xml" />
    <item id="cover-image" href="Images/cover.png" media-type="image/png" properties="cover-image" />
    <item id="font" href="Fonts/book.otf" media-type="font/otf" />
  </manifest>
  <spine><itemref idref="chapter1" /><itemref idref="chapter2" /></spine>
</package>''';
  const nav = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>目录</title></head>
  <body><nav epub:type="toc"><ol>
    <li><a href="Text/chapter1.xhtml">第一章</a></li>
    <li><a href="Text/chapter2.xhtml">第二章</a></li>
  </ol></nav></body>
</html>''';
  return _epubArchive({
    'META-INF/container.xml': _container,
    'OEBPS/content.opf': opf,
    'OEBPS/nav.xhtml': nav,
    'OEBPS/Text/chapter1.xhtml':
        '''<html xmlns="http://www.w3.org/1999/xhtml"><body onclick="bad()"><p><ruby>漢<rt>かん</rt></ruby></p><script>alert(1)</script><img src="../Images/cover.png" /></body></html>''',
    'OEBPS/Text/chapter2.xhtml': _xhtml('第二章'),
    'OEBPS/Images/cover.png': _onePixelPng,
    'OEBPS/Fonts/book.otf': [0, 1, 2, 3],
  });
}

Uint8List _epubArchive(Map<String, Object> files) {
  final archive = Archive();
  final mime = utf8.encode('application/epub+zip');
  archive.addFile(ArchiveFile.noCompress('mimetype', mime.length, mime));
  for (final item in files.entries) {
    final bytes = item.value is String
        ? utf8.encode(item.value as String)
        : List<int>.from(item.value as List<int>);
    archive.addFile(ArchiveFile(item.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

String _xhtml(String text) =>
    '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>$text</p></body></html>';

const _container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml" /></rootfiles>
</container>''';

final _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

void _zeroZipCrc(Uint8List bytes) {
  for (var index = 0; index <= bytes.length - 4; index++) {
    final isLocal = bytes[index] == 0x50 &&
        bytes[index + 1] == 0x4b &&
        bytes[index + 2] == 0x03 &&
        bytes[index + 3] == 0x04;
    final isCentral = bytes[index] == 0x50 &&
        bytes[index + 1] == 0x4b &&
        bytes[index + 2] == 0x01 &&
        bytes[index + 3] == 0x02;
    final crcOffset = isLocal
        ? index + 14
        : isCentral
            ? index + 16
            : -1;
    if (crcOffset >= 0) {
      bytes.fillRange(crcOffset, crcOffset + 4, 0);
    }
  }
}
