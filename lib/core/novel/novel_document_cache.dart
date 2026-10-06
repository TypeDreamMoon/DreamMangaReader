import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import 'models.dart';
import 'novel_document_sanitizer.dart';

class CachedNovelDocument {
  const CachedNovelDocument({
    required this.directory,
    required this.documentPath,
    required this.html,
    required this.resourceCount,
    required this.byteCount,
    this.missingResourceCount = 0,
  });

  final String directory;
  final String documentPath;
  final String html;
  final int resourceCount;
  final int byteCount;

  /// 下载失败、只能留着远程地址当占位的章内资源数量。
  final int missingResourceCount;
}

/// 一章离线缓存的体检结果:目录、正文文件路径、资源数和总字节数。
/// 只查 manifest 和文件大小,不碰正文 —— 启动时几百章逐个 readAsString
/// 会把主 isolate 卡住,而这里要的信息全在 metadata.json 和文件长度里。
class CachedNovelChapterStat {
  const CachedNovelChapterStat({
    required this.directory,
    required this.documentPath,
    required this.resourceCount,
    required this.byteCount,
    this.missingResourceCount = 0,
  });

  final String directory;
  final String documentPath;
  final int resourceCount;
  final int byteCount;

  /// 下载时抓不到、正文里仍指向远程地址的资源数。
  final int missingResourceCount;
}

class NovelDocumentCache {
  NovelDocumentCache({
    required this.root,
    required Dio dio,
    int resourceConcurrency = 4,
    Duration resourceTimeout = const Duration(seconds: 30),
  })  : _dio = dio,
        _resourceConcurrency = resourceConcurrency < 1 ? 1 : resourceConcurrency,
        _resourceTimeout = resourceTimeout;

  final String root;
  final Dio _dio;

  /// 章内资源的并发上限:一章几十张插图串行拉会把下载队列堵死。
  final int _resourceConcurrency;

  /// 单个资源的超时:一张图挂在那里不能拖住整章。
  final Duration _resourceTimeout;

  Future<CachedNovelDocument> save(
    String sourceId,
    String novelId,
    String chapterId,
    NovelDocument document, {
    Map<String, String> headers = const {},
  }) async {
    final destination = _chapterDirectory(sourceId, novelId, chapterId);
    final parent = destination.parent;
    await parent.create(recursive: true);
    final partial = Directory(
      '${destination.path}.partial-${DateTime.now().microsecondsSinceEpoch}',
    );
    await partial.create();

    Directory? backup;
    try {
      var html = _documentHtml(document);
      final resourcesDirectory = Directory(_join(partial.path, 'resources'));
      final candidates = _resourceCandidates(html, document);
      if (candidates.isNotEmpty) {
        await resourcesDirectory.create(recursive: true);
      }
      // 限流并发拉取:失败的那一个只丢掉自己,整章照样落盘。
      final stored = List<_StoredResource?>.filled(candidates.length, null);
      var cursor = 0;
      Future<void> worker() async {
        while (true) {
          final slot = cursor++;
          if (slot >= candidates.length) return;
          stored[slot] = await _fetchResource(
            candidates[slot],
            slot,
            resourcesDirectory,
            headers,
          );
        }
      }

      await Future.wait([
        for (var i = 0;
            i < _resourceConcurrency && i < candidates.length;
            i++)
          worker(),
      ]);

      final resourceMetadata = <Map<String, Object?>>[];
      final missingResources = <String>[];
      final replacements = <String, String>{};
      var resourcesBytes = 0;
      for (var slot = 0; slot < candidates.length; slot++) {
        final candidate = candidates[slot];
        final remote = candidate.remote.toString();
        final resource = stored[slot];
        if (resource == null) {
          // 留着原始远程地址当占位:联网时还能显示,离线时是一张坏图,
          // 但不会连累整章。
          missingResources.add(remote);
          continue;
        }
        resourcesBytes += resource.byteCount;
        resourceMetadata.add({
          'path': resource.path,
          'bytes': resource.byteCount,
          'source': remote,
        });
        for (final alias in candidate.aliases) {
          replacements[alias] = resource.path;
        }
        replacements[remote] = resource.path;
      }
      html = _rewriteResources(html, replacements);

      final documentFile = File(_join(partial.path, 'document.html'));
      await documentFile.writeAsString(html, encoding: utf8, flush: true);
      final documentBytes = await documentFile.length();
      final metadata = {
        'schema': 1,
        'complete': true,
        'document': 'document.html',
        'documentBytes': documentBytes,
        'resourceCount': resourceMetadata.length,
        'resources': resourceMetadata,
        'missingResources': missingResources,
        'byteCount': documentBytes + resourcesBytes,
      };
      await File(_join(partial.path, 'metadata.json')).writeAsString(
        jsonEncode(metadata),
        encoding: utf8,
        flush: true,
      );

      if (await destination.exists()) {
        backup = Directory(
          '${destination.path}.backup-${DateTime.now().microsecondsSinceEpoch}',
        );
        await destination.rename(backup.path);
      }
      try {
        await partial.rename(destination.path);
      } catch (_) {
        if (backup != null && await backup.exists()) {
          await backup.rename(destination.path);
          backup = null;
        }
        rethrow;
      }
      if (backup != null && await backup.exists()) {
        await backup.delete(recursive: true);
      }
      final cached = await read(sourceId, novelId, chapterId);
      if (cached == null) {
        throw StateError('Committed novel cache failed validation');
      }
      return cached;
    } catch (_) {
      if (await partial.exists()) await partial.delete(recursive: true);
      rethrow;
    }
  }

  /// 拉一个章内资源并落盘。失败(含超时)返回 null —— 调用方用远程地址占位。
  Future<_StoredResource?> _fetchResource(
    _ResourceCandidate candidate,
    int slot,
    Directory directory,
    Map<String, String> headers,
  ) async {
    final remote = candidate.remote.toString();
    final cancelToken = CancelToken();
    List<int>? bytes;
    try {
      final response = await _dio
          .get<List<int>>(
            remote,
            cancelToken: cancelToken,
            options: Options(
              headers: headers,
              responseType: ResponseType.bytes,
              validateStatus: (status) =>
                  status != null && status >= 200 && status < 300,
            ),
          )
          .timeout(_resourceTimeout);
      bytes = response.data;
    } on TimeoutException {
      cancelToken.cancel('novel resource timed out');
      return null;
    } catch (_) {
      return null;
    }
    if (bytes == null) return null;
    final filename = 'resource-${slot.toString().padLeft(4, '0')}'
        '${_safeExtension(candidate.extensionHint, candidate.remote.path)}';
    await File(_join(directory.path, filename)).writeAsBytes(
      bytes,
      flush: true,
    );
    return _StoredResource('resources/$filename', bytes.length);
  }

  Future<CachedNovelDocument?> read(
    String sourceId,
    String novelId,
    String chapterId,
  ) async {
    final stat = await this.stat(sourceId, novelId, chapterId);
    if (stat == null) return null;
    try {
      return CachedNovelDocument(
        directory: stat.directory,
        documentPath: stat.documentPath,
        html: await File(stat.documentPath).readAsString(),
        resourceCount: stat.resourceCount,
        byteCount: stat.byteCount,
        missingResourceCount: stat.missingResourceCount,
      );
    } catch (_) {
      return null;
    }
  }

  Future<CachedNovelChapterStat?> stat(
    String sourceId,
    String novelId,
    String chapterId,
  ) async {
    final directory = _chapterDirectory(sourceId, novelId, chapterId);
    try {
      final metadataFile = File(_join(directory.path, 'metadata.json'));
      final documentFile = File(_join(directory.path, 'document.html'));
      if (!await metadataFile.exists() || !await documentFile.exists()) {
        return null;
      }
      final decoded = jsonDecode(await metadataFile.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != 1 ||
          decoded['complete'] != true ||
          decoded['document'] != 'document.html') {
        return null;
      }
      final resources = decoded['resources'];
      if (resources is! List || decoded['resourceCount'] != resources.length) {
        return null;
      }
      var resourceBytes = 0;
      for (final value in resources) {
        if (value is! Map) return null;
        final item = value.cast<String, dynamic>();
        final relative = item['path'];
        final expectedBytes = item['bytes'];
        if (relative is! String ||
            !_safeRelativeResource(relative) ||
            expectedBytes is! int) {
          return null;
        }
        final file = File(_join(directory.path, _platformPath(relative)));
        if (!await file.exists() || await file.length() != expectedBytes) {
          return null;
        }
        resourceBytes += expectedBytes;
      }
      final documentBytes = await documentFile.length();
      if (decoded['documentBytes'] != documentBytes ||
          decoded['byteCount'] != documentBytes + resourceBytes) {
        return null;
      }
      final missing = decoded['missingResources'];
      return CachedNovelChapterStat(
        directory: directory.path,
        documentPath: documentFile.path,
        resourceCount: resources.length,
        byteCount: documentBytes + resourceBytes,
        missingResourceCount: missing is List ? missing.length : 0,
      );
    } catch (_) {
      return null;
    }
  }

  Directory _chapterDirectory(
    String sourceId,
    String novelId,
    String chapterId,
  ) {
    return Directory(_join(
      _join(
        _join(
          _join(_join(Directory(root).absolute.path, 'novels'), 'downloads'),
          _identitySegment(sourceId, 'sourceId'),
        ),
        _identitySegment(novelId, 'novelId'),
      ),
      _identitySegment(chapterId, 'chapterId'),
    ));
  }
}

class _StoredResource {
  const _StoredResource(this.path, this.byteCount);

  final String path;
  final int byteCount;
}

class _ResourceCandidate {
  _ResourceCandidate({
    required this.remote,
    required this.extensionHint,
  });

  final Uri remote;
  final String extensionHint;
  final Set<String> aliases = {};
}

List<_ResourceCandidate> _resourceCandidates(
  String sanitizedHtml,
  NovelDocument document,
) {
  final byRemote = <String, _ResourceCandidate>{};
  for (final entry in document.resources.entries) {
    final remote = _resolveRemote(document.baseUrl, entry.value);
    final candidate = byRemote.putIfAbsent(
      remote.toString(),
      () => _ResourceCandidate(remote: remote, extensionHint: entry.key),
    );
    candidate.aliases.add(_resolveLogical(document.baseUrl, entry.key));
  }

  final fragment = html_parser.parseFragment(sanitizedHtml);
  for (final image in fragment.querySelectorAll('img[src]')) {
    final src = image.attributes['src'];
    if (src == null) continue;
    if (byRemote.values.any((candidate) => candidate.aliases.contains(src))) {
      continue;
    }
    final uri = Uri.tryParse(src);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      continue;
    }
    final candidate = byRemote.putIfAbsent(
      uri.toString(),
      () => _ResourceCandidate(remote: uri, extensionHint: uri.path),
    );
    candidate.aliases.add(src);
  }
  return byRemote.values.toList(growable: false);
}

String _documentHtml(NovelDocument document) {
  final base =
      document.baseUrl == null ? null : Uri.tryParse(document.baseUrl!);
  if (document.format == NovelDocumentFormat.html) {
    return NovelDocumentSanitizer.sanitize(document.content, baseUrl: base);
  }
  const escape = HtmlEscape(HtmlEscapeMode.element);
  // 老式 Mac / 部分脚本源只发 `\r`,只切 `\r?\n` 会把整章挤成一个段落。
  final paragraphs = document.content.split(RegExp(r'\r\n?|\n')).map((line) {
    return line.isEmpty ? '<p><br></p>' : '<p>${escape.convert(line)}</p>';
  }).join();
  return NovelDocumentSanitizer.sanitize(paragraphs, baseUrl: base);
}

Uri _resolveRemote(String? baseUrl, String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null) {
    throw FormatException('Invalid novel resource URL: $value');
  }
  final base = baseUrl == null ? null : Uri.tryParse(baseUrl);
  final resolved = base?.resolveUri(parsed) ?? parsed;
  if ((resolved.scheme != 'http' && resolved.scheme != 'https') ||
      resolved.host.isEmpty) {
    throw FormatException('Unsupported novel resource URL: $value');
  }
  return resolved;
}

String _resolveLogical(String? baseUrl, String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null) return value;
  final base = baseUrl == null ? null : Uri.tryParse(baseUrl);
  return (base?.resolveUri(parsed) ?? parsed).toString();
}

String _rewriteResources(String source, Map<String, String> replacements) {
  if (replacements.isEmpty) return source;
  final fragment = html_parser.parseFragment(source);
  for (final image in fragment.querySelectorAll('img[src]')) {
    final src = image.attributes['src'];
    final replacement = src == null ? null : replacements[src];
    if (replacement != null) image.attributes['src'] = replacement;
  }
  return fragment.outerHtml;
}

String _identitySegment(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return sha256.convert(utf8.encode(value)).toString().substring(0, 24);
}

String _safeExtension(String logical, String remotePath) {
  for (final candidate in [logical, remotePath]) {
    final name = candidate.split('/').last.split('\\').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) continue;
    final extension = name.substring(dot).toLowerCase();
    if (RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) return extension;
  }
  return '.bin';
}

bool _safeRelativeResource(String value) {
  final normalized = value.replaceAll('\\', '/');
  return normalized.startsWith('resources/') &&
      !normalized.startsWith('/') &&
      !normalized.split('/').contains('..') &&
      !Uri.parse(normalized).hasScheme;
}

String _platformPath(String value) =>
    value.replaceAll('/', Platform.pathSeparator);

String _join(String parent, String child) {
  if (parent.endsWith(Platform.pathSeparator)) return '$parent$child';
  return '$parent${Platform.pathSeparator}$child';
}
