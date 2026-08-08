import 'dart:io';

import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_background_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory sandbox;
  late Directory support;
  late NovelBackgroundStore store;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('novel-background-test-');
    support = Directory('${sandbox.path}${Platform.pathSeparator}support');
    store = NovelBackgroundStore(
      applicationSupportDirectory: () async => support,
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('paper generation is deterministic and low contrast', () async {
    final first = await store.paperTexture(seed: 20260807, size: 64);
    final firstBytes = await first.file.readAsBytes();
    await first.file.delete();
    final second = await store.paperTexture(seed: 20260807, size: 64);
    final secondBytes = await second.file.readAsBytes();

    expect(secondBytes, firstBytes);
    final image = img.decodePng(secondBytes)!;
    var minimum = 255;
    var maximum = 0;
    for (final pixel in image) {
      minimum = pixel.r.toInt() < minimum ? pixel.r.toInt() : minimum;
      maximum = pixel.r.toInt() > maximum ? pixel.r.toInt() : maximum;
    }
    expect(maximum - minimum, lessThanOrEqualTo(18));
  });

  test('valid images copy under support and duplicate hashes are reused',
      () async {
    final source = await _writePng(sandbox, '阅读 背景.png');
    final duplicate = File(
      '${sandbox.path}${Platform.pathSeparator}duplicate.png',
    );
    await duplicate.writeAsBytes(await source.readAsBytes(), flush: true);

    final first = await store.importImage(source);
    final second = await store.importImage(duplicate);

    expect(first.id, startsWith(NovelBackgroundIds.importedPrefix));
    expect(first.file.path, startsWith(support.path));
    expect(second.file.path, first.file.path);
    expect(await store.listImported(), hasLength(1));
  });

  test('invalid, missing and corrupt images fall back to theme color',
      () async {
    final invalid = File('${sandbox.path}${Platform.pathSeparator}bad.png');
    await invalid.writeAsBytes([1, 2, 3, 4], flush: true);

    await expectLater(
      store.importImage(invalid),
      throwsA(isA<NovelBackgroundException>()),
    );
    expect(
      await store.resolve(
        '${NovelBackgroundIds.importedPrefix}${List.filled(64, 'a').join()}',
      ),
      isNull,
    );

    final imported =
        await store.importImage(await _writePng(sandbox, 'ok.png'));
    await imported.file.writeAsBytes([9, 8, 7], flush: true);
    expect(await store.resolve(imported.id), isNull);
  });

  test('valid image content replaced under a hash ID is rejected', () async {
    final imported = await store.importImage(
      await _writePng(sandbox, 'hashed.png'),
    );
    final replacement = await _writePng(sandbox, 'replacement.png', red: 12);
    await imported.file.writeAsBytes(
      await replacement.readAsBytes(),
      flush: true,
    );

    expect(await store.resolve(imported.id), isNull);
  });

  test('reimport repairs a corrupt hash-named cache file', () async {
    final source = await _writePng(sandbox, 'repair-source.png');
    final expectedBytes = await source.readAsBytes();
    final imported = await store.importImage(source);
    await imported.file.writeAsBytes([9, 8, 7], flush: true);

    final repaired = await store.importImage(source);

    expect(repaired.id, imported.id);
    expect(await repaired.file.readAsBytes(), expectedBytes);
    expect(await store.resolve(repaired.id), isNotNull);
  });

  test('rejects oversized files before decoding them', () async {
    final source = File('${sandbox.path}${Platform.pathSeparator}huge.png');
    final handle = await source.open(mode: FileMode.write);
    await handle.truncate(NovelBackgroundStore.maxImportBytes + 1);
    await handle.close();

    await expectLater(
      store.importImage(source),
      throwsA(
        isA<NovelBackgroundException>().having(
          (error) => error.code,
          'code',
          NovelBackgroundError.imageTooLarge,
        ),
      ),
    );
  });

  test('dark custom backgrounds select a readable automatic foreground',
      () async {
    final imported = await store.importImage(
      await _writePng(sandbox, 'dark.png', red: 8, green: 8, blue: 8),
    );
    final profile = novelReaderThemeProfile(
      NovelReaderTheme.white,
      readabilityBackgroundArgb: imported.averageArgb,
    );

    expect(profile.foregroundArgb, 0xffeeeeee);
  });

  test('unreferenced cleanup removes valid and corrupt imported files',
      () async {
    final retained = await store.importImage(
      await _writePng(sandbox, 'retained.png'),
    );
    final discarded = await store.importImage(
      await _writePng(sandbox, 'discarded.png', red: 224),
    );
    await discarded.file.writeAsBytes([9, 8, 7], flush: true);

    await store.deleteUnreferenced({retained.id});

    expect(await retained.file.exists(), isTrue);
    expect(await discarded.file.exists(), isFalse);
  });

  test('portable settings exclude custom image IDs, bytes and paths', () async {
    final imported = await store.importImage(
      await _writePng(sandbox, 'private-background.png'),
    );
    final preferences = NovelReaderPreferences(
      theme: NovelReaderTheme.paper,
      backgroundAssetId: imported.id,
      backgroundFit: NovelBackgroundFit.tile,
      textureStrength: .45,
    );

    final library = NovelLibraryStore();
    addTearDown(library.dispose);
    library.setPreferences(preferences);
    final portable = library.exportData()['settings'].toString();

    expect(portable, isNot(contains(imported.id)));
    expect(portable, isNot(contains(imported.file.path)));
    expect(portable, isNot(contains('89504e47')));
    expect(portable, contains('tile'));
  });
}

Future<File> _writePng(
  Directory directory,
  String name, {
  int red = 225,
  int green = 218,
  int blue = 196,
}) async {
  final image = img.Image(width: 12, height: 8);
  img.fill(image, color: img.ColorRgb8(red, green, blue));
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(img.encodePng(image), flush: true);
  return file;
}
