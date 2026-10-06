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
    final index = jsonEncode(_buildIndex(preview));
    // 目录名仍旧是 sha256(书架条目与阅读进度都挂在它上面),但同一份文件换个
    // 编码或改个书名再导一次,解析结果是新的 —— 旧目录得让位,不能白导。
    if (await _isInstalled(destination, index)) return destination;

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
        index,
        encoding: utf8,
        flush: true,
      );
      final installed = await _replace(temporary, destination, novels);
      // 规范化后的中间文本只服务这次导入,装好就删。
      await _deleteQuietly(File(preview.normalizedTextPath));
      return installed;
    } catch (_) {
      if (await temporary.exists()) await temporary.delete(recursive: true);
      if (await destination.exists()) return destination;
      rethrow;
    }
  }

  /// 目标目录里已经是同一份解析结果吗?是的话重复导入就是个空操作。
  Future<bool> _isInstalled(Directory destination, String index) async {
    try {
      if (!await File(_join(destination.path, 'content.txt')).exists()) {
        return false;
      }
      final file = File(_join(destination.path, 'index.json'));
      return await file.exists() && await file.readAsString() == index;
    } catch (_) {
      return false;
    }
  }

  /// 原子替换:先把旧目录挪走,装好新的再删旧的;装不上就把旧的放回去。
  Future<Directory> _replace(
    Directory temporary,
    Directory destination,
    Directory novels,
  ) async {
    Directory? stale;
    if (await destination.exists()) {
      stale = Directory(_join(
        novels.path,
        '.stale-$pid-${DateTime.now().microsecondsSinceEpoch}',
      ));
      await destination.rename(stale.path);
    }
    try {
      final installed = await temporary.rename(destination.path);
      if (stale != null && await stale.exists()) {
        await stale.delete(recursive: true);
      }
      return installed;
    } catch (_) {
      if (stale != null &&
          await stale.exists() &&
          !await destination.exists()) {
        await stale.rename(destination.path);
      }
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
