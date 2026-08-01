import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'novel_encoding.dart';
import 'txt_chapter_parser.dart';

typedef ApplicationSupportDirectory = Future<Directory> Function();

class TxtNovelImportPreview extends ImportedNovelPreview {
  const TxtNovelImportPreview({
    required super.sha256,
    required super.title,
    required super.authors,
    required super.chapters,
    required this.encoding,
    required this.normalizedText,
    required this.parsed,
  }) : super(origin: NovelOrigin.localTxt);

  final String encoding;
  final String normalizedText;
  final TxtChapterParseResult parsed;
}

class TxtNovelImporter {
  TxtNovelImporter({
    NovelTextDecoder? decoder,
    ApplicationSupportDirectory? applicationSupportDirectory,
  })  : _decoder = decoder ?? NovelTextDecoder(),
        _applicationSupportDirectory =
            applicationSupportDirectory ?? getApplicationSupportDirectory;

  final NovelTextDecoder _decoder;
  final ApplicationSupportDirectory _applicationSupportDirectory;

  Future<TxtNovelImportPreview> preview(
    File source, {
    String? forcedEncoding,
  }) async {
    final bytes = await source.readAsBytes();
    final decoded = await _decoder.decode(
      bytes,
      forcedEncoding: forcedEncoding,
    );
    final fallbackTitle = _filenameWithoutExtension(source);
    return Isolate.run(
      () => _buildPreview(bytes, decoded, fallbackTitle),
    );
  }

  Future<Directory> importPreview(TxtNovelImportPreview preview) async {
    final support = await _applicationSupportDirectory();
    final novels = Directory(_join(support.path, 'novels'));
    final local = Directory(_join(novels.path, 'local'));
    await local.create(recursive: true);

    final destination = Directory(_join(local.path, preview.sha256));
    if (await destination.exists()) return destination;

    final temporary = Directory(
      _join(
        novels.path,
        '.tmp-${preview.sha256}-$pid-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await temporary.create();
    try {
      await File(_join(temporary.path, 'content.txt')).writeAsString(
        preview.normalizedText,
        encoding: utf8,
        flush: true,
      );
      await File(_join(temporary.path, 'index.json')).writeAsString(
        jsonEncode(_buildIndex(preview)),
        encoding: utf8,
        flush: true,
      );
      if (await destination.exists()) {
        await temporary.delete(recursive: true);
        return destination;
      }
      return temporary.rename(destination.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete(recursive: true);
      if (await destination.exists()) return destination;
      rethrow;
    }
  }

  Map<String, Object?> _buildIndex(TxtNovelImportPreview preview) {
    return {
      'schema': 1,
      'sha256': preview.sha256,
      'origin': 'localTxt',
      'encoding': preview.encoding,
      'title': preview.title,
      'authors': preview.authors,
      'metadata': {
        'preface': preview.parsed.metadata.preface,
      },
      'volumes': preview.parsed.volumes
          .map(
            (volume) => {
              'id': volume.id,
              'title': volume.title,
              'offset': volume.offset,
              'chapterIds': volume.chapters
                  .map((chapter) => chapter.id)
                  .toList(growable: false),
            },
          )
          .toList(growable: false),
      'chapters': preview.parsed.chapters
          .map(
            (chapter) => {
              'id': chapter.id,
              'title': chapter.title,
              'number': chapter.number,
              'offset': chapter.offset,
              'contentOffset': chapter.contentOffset,
              'endOffset': chapter.endOffset,
              'volumeId': chapter.volumeId,
              'volumeTitle': chapter.volumeTitle,
            },
          )
          .toList(growable: false),
    };
  }
}

TxtNovelImportPreview _buildPreview(
  List<int> bytes,
  DecodedNovelText decoded,
  String fallbackTitle,
) {
  final parsed = TxtChapterParser.parse(decoded.text);
  final title = parsed.metadata.title ?? fallbackTitle;
  final authors = parsed.metadata.author == null
      ? const <String>[]
      : <String>[parsed.metadata.author!];
  final chapters = parsed.chapters
      .map(
        (chapter) => NovelChapter(
          id: chapter.id,
          title: chapter.title,
          number: chapter.number?.toDouble(),
          volumeId: chapter.volumeId,
          volumeTitle: chapter.volumeTitle,
        ),
      )
      .toList(growable: false);

  return TxtNovelImportPreview(
    sha256: sha256.convert(bytes).toString(),
    title: title,
    authors: List.unmodifiable(authors),
    chapters: List.unmodifiable(chapters),
    encoding: decoded.encoding,
    normalizedText: parsed.normalizedText,
    parsed: parsed,
  );
}

String _filenameWithoutExtension(File source) {
  final name = source.uri.pathSegments.isEmpty
      ? source.path
      : source.uri.pathSegments.last;
  return name.toLowerCase().endsWith('.txt')
      ? name.substring(0, name.length - 4)
      : name;
}

String _join(String parent, String child) {
  if (parent.endsWith(Platform.pathSeparator)) return '$parent$child';
  return '$parent${Platform.pathSeparator}$child';
}
