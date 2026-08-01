import 'package:archive/archive.dart';
import 'package:dream_manga_reader/core/novel/import/epub_preflight.dart';
import 'package:flutter_test/flutter_test.dart';

ArchiveFile entry(
  String name, {
  int size = 1,
  int compressedSize = 1,
}) {
  return ArchiveFile(name, size, List<int>.filled(compressedSize, 0));
}

void main() {
  test('accepts normalized relative EPUB entries', () {
    final entries = EpubPreflight.validate([
      entry('META-INF/container.xml'),
      entry('OEBPS/text/chapter.xhtml'),
    ]);

    expect(entries.map((item) => item.relativePath), [
      'META-INF/container.xml',
      'OEBPS/text/chapter.xhtml',
    ]);
  });

  test('rejects traversal and absolute EPUB entries', () {
    for (final name in [
      '../escape.xhtml',
      'OEBPS/../../escape.xhtml',
      '/root.xhtml',
      r'C:\root.xhtml',
      r'\\server\share\root.xhtml',
    ]) {
      expect(
        () => EpubPreflight.validate([entry(name)]),
        throwsFormatException,
        reason: name,
      );
    }
  });

  test('rejects symbolic links and duplicate normalized paths', () {
    final link = entry('OEBPS/link.xhtml')..isSymbolicLink = true;
    expect(
      () => EpubPreflight.validate([link]),
      throwsFormatException,
    );
    expect(
      () => EpubPreflight.validate([
        entry('OEBPS/text/../chapter.xhtml'),
        entry('OEBPS/chapter.xhtml'),
      ]),
      throwsFormatException,
    );
    expect(
      () => EpubPreflight.validate([
        entry('OEBPS/Text/Chapter.xhtml'),
        entry('oebps/text/chapter.xhtml'),
      ]),
      throwsFormatException,
    );
  });

  test('rejects Windows-unsafe archive path segments on every platform', () {
    for (final name in [
      'OEBPS/file:stream',
      'OEBPS/NUL.txt',
      'OEBPS/COM1',
      'OEBPS/trailing.',
      'OEBPS/trailing ',
    ]) {
      expect(
        () => EpubPreflight.validate([entry(name)]),
        throwsFormatException,
        reason: name,
      );
    }
  });

  test('resolves manifest href below the archive root', () {
    expect(
      EpubPreflight.resolveRelativePath(
        'OEBPS/package',
        '../Images/cover.jpg',
      ),
      'OEBPS/Images/cover.jpg',
    );
    expect(
      () => EpubPreflight.resolveRelativePath(
        'OEBPS/package',
        '../../../escape.jpg',
      ),
      throwsFormatException,
    );
  });

  test('rejects excessive entry count, sizes, totals and compression ratio',
      () {
    expect(
      () => EpubPreflight.validate(
        List.generate(20001, (index) => entry('f$index')),
      ),
      throwsFormatException,
    );
    expect(
      () => EpubPreflight.validate([
        entry('OEBPS/a.xhtml', size: 129 * 1024 * 1024),
      ]),
      throwsFormatException,
    );
    expect(
      () => EpubPreflight.validate(
        List.generate(
          9,
          (index) => entry(
            'OEBPS/$index.bin',
            size: 128 * 1024 * 1024,
            compressedSize: 1024 * 1024,
          ),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => EpubPreflight.validate([
        entry(
          'OEBPS/bomb.xhtml',
          size: 2 * 1024 * 1024,
          compressedSize: 1024,
        ),
      ]),
      throwsFormatException,
    );
  });
}
