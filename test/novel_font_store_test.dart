import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_font_store.dart';
import 'package:dream_manga_reader/features/novel/novel_document_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late Directory support;
  late NovelFontStore store;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('novel-font-test-');
    support = Directory('${sandbox.path}${Platform.pathSeparator}support');
    store = NovelFontStore(
      applicationSupportDirectory: () async => support,
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('imports valid TTF and OTF signatures under application support',
      () async {
    final ttf = await _writeFixture(
      sandbox,
      'Reader Font.ttf',
      _minimalFont('ttf'),
    );
    final otf = await _writeFixture(
      sandbox,
      'Reader Serif.otf',
      _minimalFont('otf'),
    );

    final importedTtf = await store.importFont(ttf);
    final importedOtf = await store.importFont(otf);

    expect(importedTtf.id, startsWith(NovelFontIds.importedPrefix));
    expect(importedOtf.id, startsWith(NovelFontIds.importedPrefix));
    expect(importedTtf.file.path, startsWith(support.path));
    expect(importedOtf.file.path, startsWith(support.path));
    expect(await importedTtf.file.readAsBytes(), _minimalFont('ttf'));
    expect(await importedOtf.file.readAsBytes(), _minimalFont('otf'));
  });

  test('copies a built-in font under application support before WebView use',
      () async {
    final bytes = await File(
      'assets/fonts/NotoSerifSC-Regular.otf',
    ).readAsBytes();
    final loadedAssets = <String>[];
    final builtInStore = NovelFontStore(
      applicationSupportDirectory: () async => support,
      loadAsset: (path) async {
        loadedAssets.add(path);
        return bytes;
      },
    );

    final record = await builtInStore.resolveForUse(NovelFontIds.notoSerifSc);

    expect(record.id, NovelFontIds.notoSerifSc);
    expect(record.file.path, startsWith(support.path));
    expect(await record.file.readAsBytes(), bytes);
    expect(loadedAssets, ['assets/fonts/NotoSerifSC-Regular.otf']);
  });

  test('builds a quoted file URL font-face from a stable font record',
      () async {
    final source = await _writeFixture(
      sandbox,
      'Reader Font.ttf',
      _minimalFont('ttf'),
    );
    final imported = await store.importFont(source);

    final css = buildNovelFontFaceCss(imported);

    expect(css, contains('@font-face'));
    expect(css, contains(imported.cssFamily));
    expect(css, contains(imported.file.uri.toString()));
    expect(imported.id, startsWith(NovelFontIds.importedPrefix));
  });

  test('rejects truncated fonts and table ranges outside the file', () async {
    final truncated = await _writeFixture(
      sandbox,
      'truncated.ttf',
      const [0, 1, 0, 0, 0, 1],
    );
    final outOfBounds = _minimalFont('otf')..[27] = 40;
    final malformed = await _writeFixture(
      sandbox,
      'malformed.otf',
      outOfBounds,
    );

    await expectLater(
      store.importFont(truncated),
      throwsA(
        isA<NovelFontImportException>().having(
          (error) => error.code,
          'code',
          NovelFontImportError.invalidStructure,
        ),
      ),
    );
    await expectLater(
      store.importFont(malformed),
      throwsA(isA<NovelFontImportException>()),
    );
  });

  test('rejects fonts missing required OpenType tables', () async {
    final source = await _writeFixture(
      sandbox,
      'missing-tables.ttf',
      _singleTableFont('ttf'),
    );

    await expectLater(
      store.importFont(source),
      throwsA(
        isA<NovelFontImportException>().having(
          (error) => error.code,
          'code',
          NovelFontImportError.invalidStructure,
        ),
      ),
    );
  });

  test('rejects fonts larger than the import limit before reading them',
      () async {
    final source = File('${sandbox.path}${Platform.pathSeparator}huge.ttf');
    final handle = await source.open(mode: FileMode.write);
    await handle.writeFrom(_minimalFont('ttf'));
    await handle.truncate(64 * 1024 * 1024 + 1);
    await handle.close();

    await expectLater(
      store.importFont(source),
      throwsA(
        isA<NovelFontImportException>().having(
          (error) => error.code.name,
          'code',
          'fileTooLarge',
        ),
      ),
    );
  });

  test('rejects unsupported file extensions before copying', () async {
    final source = await _writeFixture(
      sandbox,
      'reader-font.woff',
      _minimalFont('ttf'),
    );

    await expectLater(
      store.importFont(source),
      throwsA(
        isA<NovelFontImportException>().having(
          (error) => error.code,
          'code',
          NovelFontImportError.unsupportedExtension,
        ),
      ),
    );
    expect(await support.exists(), isFalse);
  });

  test('sanitizes names and reuses a duplicate SHA-256 import', () async {
    final bytes = _minimalFont('ttf');
    final first = await _writeFixture(
      sandbox,
      '  Reader(Font) @  .ttf',
      bytes,
    );
    final second = await _writeFixture(sandbox, 'duplicate.ttf', bytes);

    final importedFirst = await store.importFont(first);
    final importedSecond = await store.importFont(second);
    final files = await store.listImportedFonts();

    expect(
      importedFirst.id,
      '${NovelFontIds.importedPrefix}${sha256.convert(bytes)}',
    );
    expect(importedFirst.file.path, importedSecond.file.path);
    expect(importedFirst.displayName, 'Reader_Font');
    expect(importedFirst.file.uri.pathSegments.last, isNot(contains('(')));
    expect(importedFirst.file.uri.pathSegments.last, isNot(contains('@')));
    expect(files, hasLength(1));
  });

  test('deleting the selected import falls back to built-in Noto Serif SC',
      () async {
    final source = await _writeFixture(
      sandbox,
      'temporary.ttf',
      _minimalFont('ttf'),
    );
    final imported = await store.importFont(source);

    final selected = await store.deleteFont(
      imported.id,
      selectedId: imported.id,
    );

    expect(selected, NovelFontIds.notoSerifSc);
    expect(await imported.file.exists(), isFalse);
    expect(await store.resolveFont(imported.id), isNull);
  });

  test('does not resolve a hash-named import after its contents change',
      () async {
    final source = await _writeFixture(
      sandbox,
      'mutable.ttf',
      _minimalFont('ttf'),
    );
    final imported = await store.importFont(source);
    final modified = await imported.file.readAsBytes();
    modified[modified.length - 1] ^= 0xff;
    await imported.file.writeAsBytes(modified, flush: true);

    expect(await store.resolveFont(imported.id), isNull);
  });

  test('rewrites a modified built-in cache from the official asset', () async {
    final bytes = await File(
      'assets/fonts/NotoSerifSC-Regular.otf',
    ).readAsBytes();
    final builtInStore = NovelFontStore(
      applicationSupportDirectory: () async => support,
      loadAsset: (_) async => bytes,
    );
    final first = await builtInStore.resolveForUse(NovelFontIds.notoSerifSc);
    final modified = await first.file.readAsBytes();
    modified[modified.length - 1] ^= 0xff;
    await first.file.writeAsBytes(modified, flush: true);

    final restored = await builtInStore.resolveForUse(
      NovelFontIds.notoSerifSc,
    );

    expect(await restored.file.readAsBytes(), bytes);
  });

  test('preferences migrate legacy families and serialize only stable IDs', () {
    final legacy = NovelReaderPreferences.fromJson(const {
      'fontFamily': 'serif',
    });
    final unsafe = const NovelReaderPreferences(
      fontFamily: r'C:\Users\reader\private-font.ttf',
    ).toJson();
    final importedId =
        '${NovelFontIds.importedPrefix}${List.filled(64, 'a').join()}';
    final imported = NovelReaderPreferences.fromJson({
      'fontFamily': importedId,
    });

    expect(legacy.fontFamily, NovelFontIds.notoSerifSc);
    expect(unsafe['fontFamily'], NovelFontIds.notoSerifSc);
    expect(unsafe.toString(), isNot(contains('private-font.ttf')));
    expect(imported.fontFamily, importedId);
  });

  test('WebView bridge loads registered font faces and reports visible text',
      () {
    expect(novelReaderBridgeScript, contains('p.fontFaceCss'));
    expect(novelReaderBridgeScript, contains('document.fonts.load'));
    expect(novelReaderBridgeScript, contains('loadedFaces.length === 0'));
    expect(novelReaderBridgeScript, contains('visibleTextLength'));

    final metrics = parseNovelPageMetrics({
      'pageCount': 1,
      'currentPageIndex': 0,
      'viewportWidth': 360,
      'viewportHeight': 800,
      'visibleTextLength': 42,
    });
    expect(metrics?.visibleTextLength, 42);
  });

  test('WebView permits CSP-scoped file font loading', () {
    final settings = buildNovelDocumentWebViewSettings();

    expect(settings.allowFileAccess, isTrue);
    expect(settings.allowFileAccessFromFileURLs, isTrue);
  });
}

Future<File> _writeFixture(
  Directory directory,
  String name,
  List<int> bytes,
) async {
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

List<int> _minimalFont(String format) {
  final signature = format == 'otf'
      ? const [0x4f, 0x54, 0x54, 0x4f]
      : const [0x00, 0x01, 0x00, 0x00];
  final tags = <String>[
    'OS/2',
    'cmap',
    'head',
    'hhea',
    'hmtx',
    'maxp',
    'name',
    'post',
    if (format == 'otf') 'CFF ' else ...['glyf', 'loca'],
  ];
  final dataStart = 12 + tags.length * 16;
  return <int>[
    ...signature,
    ..._uint16(tags.length),
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    for (var index = 0; index < tags.length; index++) ...[
      ...tags[index].codeUnits,
      0x00,
      0x00,
      0x00,
      0x00,
      ..._uint32(dataStart + index),
      0x00,
      0x00,
      0x00,
      0x01,
    ],
    ...List<int>.filled(tags.length, 0),
  ];
}

List<int> _singleTableFont(String format) => [
      if (format == 'otf') ...[0x4f, 0x54, 0x54, 0x4f] else ...[0, 1, 0, 0],
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      ...'name'.codeUnits,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x1c,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
    ];

List<int> _uint16(int value) => [value >> 8 & 0xff, value & 0xff];

List<int> _uint32(int value) => [
      value >> 24 & 0xff,
      value >> 16 & 0xff,
      value >> 8 & 0xff,
      value & 0xff,
    ];
