import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
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
    required this.normalizedTextPath,
    required this.outline,
  }) : super(origin: NovelOrigin.localTxt);

  final String encoding;

  /// 规范化正文的落地文件(系统临时目录)。整本书不跟着预览在 isolate 之间
  /// 来回拷贝,确认导入时直接把这个文件搬进书库。
  final String normalizedTextPath;

  final TxtNovelOutline outline;
}

class TxtNovelImporter {
  TxtNovelImporter({
    LegacyCharsetDecoder? legacyDecoder,
    ApplicationSupportDirectory? applicationSupportDirectory,
  })  : _legacyDecoder = legacyDecoder ?? const PlatformLegacyCharsetDecoder(),
        _applicationSupportDirectory =
            applicationSupportDirectory ?? getApplicationSupportDirectory;

  final LegacyCharsetDecoder _legacyDecoder;
  final ApplicationSupportDirectory _applicationSupportDirectory;

  /// 读文件、探编码、解码、切章全在一个后台 isolate 里跑完。以前读和解码在
  /// 主 isolate,再把整份字节和整份字符串拷进 isolate、把整本书拷回来 ——
  /// 一本几十兆的 TXT 能把界面卡上好几秒。现在进去的只有路径,出来的只有
  /// 目录表,正文直接写在临时文件里。
  Future<TxtNovelImportPreview> preview(
    File source, {
    String? forcedEncoding,
  }) async {
    final scratch = Directory(
      _join(Directory.systemTemp.path, 'dmr-novel-import'),
    );
    await scratch.create(recursive: true);
    final token = RootIsolateToken.instance;
    final legacyDecoder = _legacyDecoder;
    final path = source.path;
    final scratchPath = scratch.path;
    final fallbackTitle = _filenameWithoutExtension(source);
    return Isolate.run(
      () => _buildPreview(
        path,
        scratchPath,
        legacyDecoder,
        token,
        forcedEncoding,
        fallbackTitle,
      ),
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
      await File(preview.normalizedTextPath).copy(
        _join(temporary.path, 'content.txt'),
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
      final installed = await temporary.rename(destination.path);
      await _deleteQuietly(File(preview.normalizedTextPath));
      return installed;
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
        'preface': preview.outline.metadata.preface,
      },
      'volumes': preview.outline.volumes
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
      'chapters': preview.outline.chapters
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

Future<TxtNovelImportPreview> _buildPreview(
  String path,
  String scratchPath,
  LegacyCharsetDecoder legacyDecoder,
  RootIsolateToken? token,
  String? forcedEncoding,
  String fallbackTitle,
) async {
  if (token != null) {
    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    } catch (_) {
      // 没有引擎可挂(纯 Dart / 单测)时,平台字符集会自己降级到纯 Dart GBK。
    }
  }
  final bytes = await File(path).readAsBytes();
  final digest = sha256.convert(bytes).toString();
  final decoded = await NovelTextDecoder(legacyDecoder).decode(
    bytes,
    forcedEncoding: forcedEncoding,
  );
  final parsed = TxtChapterParser.parse(decoded.text);
  final normalized = File(_join(scratchPath, '$digest.txt'));
  await normalized.writeAsString(
    parsed.normalizedText,
    encoding: utf8,
    flush: true,
  );
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
    sha256: digest,
    title: title,
    authors: List.unmodifiable(authors),
    chapters: List.unmodifiable(chapters),
    encoding: decoded.encoding,
    normalizedTextPath: normalized.path,
    outline: parsed.outline,
  );
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // 临时文件删不掉不是导入失败,系统迟早会清。
  }
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
