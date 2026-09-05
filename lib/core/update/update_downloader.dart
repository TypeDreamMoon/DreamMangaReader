import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'update_models.dart';

class UpdateIntegrityException implements Exception {
  const UpdateIntegrityException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null ? message : '$message ($statusCode)';
}

class UpdateFileVerifier {
  const UpdateFileVerifier._();

  static Future<void> verify(
    File file, {
    required int expectedSize,
    required String expectedSha256,
  }) async {
    final actualSize = await file.length();
    if (actualSize != expectedSize) {
      await _deleteIfPresent(file);
      throw UpdateIntegrityException(
        'Update size mismatch: expected $expectedSize, got $actualSize',
      );
    }

    final actualSha256 = (await sha256.bind(file.openRead()).first).toString();
    if (actualSha256.toLowerCase() != expectedSha256.toLowerCase()) {
      await _deleteIfPresent(file);
      throw const UpdateIntegrityException('Update SHA-256 mismatch');
    }
  }

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Preserve the integrity error even if cleanup is blocked externally.
    }
  }
}

class UpdateDownloader {
  UpdateDownloader({Dio? dio, this.cacheDirectory})
      : _dio = dio ??
            Dio(
              BaseOptions(
                headers: {'User-Agent': 'DreamMangaReader-Updater'},
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 60),
                followRedirects: true,
                maxRedirects: 6,
              ),
            );

  final Dio _dio;
  final Directory? cacheDirectory;

  Future<File> download(
    ResolvedUpdateAsset asset, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
    Set<String> activePaths = const {},
  }) async {
    final cache = await _resolveCacheDirectory();
    try {
      return await _download(
        asset,
        cache: cache,
        onProgress: onProgress,
        cancelToken: cancelToken,
        activePaths: activePaths,
      );
    } catch (error) {
      // 用户主动取消 = 这次更新不要了:半包(`.download`)、拼装中的临时文件和已
      // 下好的分片都得跟着走,否则它们只会躺在缓存目录里——`cleanup` 只在成功的
      // 末尾跑,而且刻意跳过 `.download`,谁也不会来收。
      //
      // 网络断了则相反:临时文件是续传的本钱,留着(设计文档明确要求),由启动时
      // 的 [UpdateCacheCleaner.sweepStale] 兜底清掉长期没人管的残留。
      if (_isCancellation(error, cancelToken)) {
        await UpdateCacheCleaner.discardAsset(cache, asset);
      }
      rethrow;
    }
  }

  static bool _isCancellation(Object error, CancelToken? cancelToken) =>
      (error is DioException && error.type == DioExceptionType.cancel) ||
      cancelToken?.isCancelled == true;

  Future<File> _download(
    ResolvedUpdateAsset asset, {
    required Directory cache,
    required void Function(double progress)? onProgress,
    required CancelToken? cancelToken,
    required Set<String> activePaths,
  }) async {
    await cache.create(recursive: true);
    final cacheName = '${asset.sha256.toLowerCase()}-${asset.fileName}';
    final finalFile = File('${cache.path}${Platform.pathSeparator}$cacheName');

    if (await finalFile.exists()) {
      try {
        await UpdateFileVerifier.verify(
          finalFile,
          expectedSize: asset.sizeBytes,
          expectedSha256: asset.sha256,
        );
        await UpdateCacheCleaner.cleanup(
          cache,
          activePaths: {...activePaths, finalFile.path},
        );
        onProgress?.call(1);
        return finalFile;
      } on UpdateIntegrityException {
        // 校验器已经删除损坏缓存，继续重新下载。
      }
    }

    if (asset.isChunked) {
      return _downloadChunked(
        asset,
        cache: cache,
        finalFile: finalFile,
        onProgress: onProgress,
        cancelToken: cancelToken,
        activePaths: activePaths,
      );
    }

    final url = asset.url;
    if (url == null || url.isEmpty) {
      throw const UpdateDownloadException('Update asset has no download URL');
    }
    final downloaded = await _downloadVerifiedRemote(
      cache: cache,
      fileName: asset.fileName,
      url: url,
      expectedSize: asset.sizeBytes,
      expectedSha256: asset.sha256,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    await UpdateCacheCleaner.cleanup(
      cache,
      activePaths: {...activePaths, downloaded.path},
    );
    return downloaded;
  }

  Future<File> _downloadChunked(
    ResolvedUpdateAsset asset, {
    required Directory cache,
    required File finalFile,
    required void Function(double progress)? onProgress,
    required CancelToken? cancelToken,
    required Set<String> activePaths,
  }) async {
    final partFiles = <File>[];
    var completedBytes = 0;
    for (final part in asset.parts) {
      final partFile = await _downloadVerifiedRemote(
        cache: cache,
        fileName: part.fileName,
        url: part.url,
        expectedSize: part.sizeBytes,
        expectedSha256: part.sha256,
        cancelToken: cancelToken,
        onProgress: (progress) {
          final received = completedBytes + (part.sizeBytes * progress);
          onProgress?.call((received / asset.sizeBytes).clamp(0, 1));
        },
      );
      partFiles.add(partFile);
      completedBytes += part.sizeBytes;
    }
    onProgress?.call(1);

    final assemblingFile = File('${finalFile.path}.assembling');
    if (await assemblingFile.exists()) await assemblingFile.delete();
    final sink = assemblingFile.openWrite(mode: FileMode.write);
    try {
      for (final partFile in partFiles) {
        await for (final chunk in partFile.openRead()) {
          final cancelError = cancelToken?.cancelError;
          if (cancelError != null) throw cancelError;
          sink.add(chunk);
        }
      }
      await sink.flush();
    } catch (_) {
      await sink.close();
      try {
        if (await assemblingFile.exists()) await assemblingFile.delete();
      } on FileSystemException {
        // A later retry will replace the incomplete assembly.
      }
      rethrow;
    }
    await sink.close();

    await UpdateFileVerifier.verify(
      assemblingFile,
      expectedSize: asset.sizeBytes,
      expectedSha256: asset.sha256,
    );
    final completed = await assemblingFile.rename(finalFile.path);
    for (final partFile in partFiles) {
      try {
        if (await partFile.exists()) await partFile.delete();
      } on FileSystemException {
        // Cache cleanup retries locked part files on a later update.
      }
    }
    await UpdateCacheCleaner.cleanup(
      cache,
      activePaths: {...activePaths, completed.path},
    );
    return completed;
  }

  Future<File> _downloadVerifiedRemote({
    required Directory cache,
    required String fileName,
    required String url,
    required int expectedSize,
    required String expectedSha256,
    required void Function(double progress)? onProgress,
    required CancelToken? cancelToken,
  }) async {
    final cacheName = '${expectedSha256.toLowerCase()}-$fileName';
    final finalFile = File('${cache.path}${Platform.pathSeparator}$cacheName');
    final partialFile = File('${finalFile.path}.download');

    if (await finalFile.exists()) {
      try {
        await UpdateFileVerifier.verify(
          finalFile,
          expectedSize: expectedSize,
          expectedSha256: expectedSha256,
        );
        onProgress?.call(1);
        return finalFile;
      } on UpdateIntegrityException {
        // 校验器已经删除损坏缓存，继续重新下载。
      }
    }

    var partialLength =
        await partialFile.exists() ? await partialFile.length() : 0;
    if (partialLength >= expectedSize) {
      try {
        await UpdateFileVerifier.verify(
          partialFile,
          expectedSize: expectedSize,
          expectedSha256: expectedSha256,
        );
        return _completePartial(partialFile, finalFile, onProgress);
      } on UpdateIntegrityException {
        partialLength = 0;
      }
    }

    final requestedResume = partialLength > 0;
    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
        headers: requestedResume ? {'Range': 'bytes=$partialLength-'} : null,
      ),
    );
    final statusCode = response.statusCode;
    final append = requestedResume && statusCode == HttpStatus.partialContent;
    if (append) {
      _validateContentRange(response.headers, partialLength);
    } else if (statusCode == HttpStatus.ok) {
      partialLength = 0;
    } else {
      throw UpdateDownloadException(
        'Unexpected update download response',
        statusCode: statusCode,
      );
    }

    final body = response.data;
    if (body == null) {
      throw const UpdateDownloadException('Update response has no body');
    }
    final sink = partialFile.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    var received = partialLength;
    try {
      await for (final chunk in body.stream) {
        final cancelError = cancelToken?.cancelError;
        if (cancelError != null) throw cancelError;
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call((received / expectedSize).clamp(0, 1));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    await UpdateFileVerifier.verify(
      partialFile,
      expectedSize: expectedSize,
      expectedSha256: expectedSha256,
    );
    return _completePartial(partialFile, finalFile, onProgress);
  }

  Future<Directory> _resolveCacheDirectory() async =>
      cacheDirectory ?? await defaultCacheDirectory();

  /// 更新包缓存目录(未注入 [cacheDirectory] 时的默认位置)。
  /// 公开给启动时的残留清理用,免得清理方自己再拼一遍路径。
  static Future<Directory> defaultCacheDirectory() async {
    final temp = await getTemporaryDirectory();
    return Directory(
      '${temp.path}${Platform.pathSeparator}dream_manga_reader_updates',
    );
  }

  /// 校验 206 的续传起点。RFC 9110 允许总长度未知时写 `*`(`bytes 100-199/*`),
  /// CDN 在分片回源时经常这么回;之前只认 `/<digits>` 会把合法响应判成非法,
  /// 续传直接失败。分隔空格也放宽成任意空白(个别代理会重写成多个空格)。
  /// 真正要守住的只有一件事:起点必须等于本地已有的字节数。
  static void _validateContentRange(Headers headers, int expectedStart) {
    final value = headers.value('content-range');
    final match = value == null
        ? null
        : RegExp(r'^bytes\s+(\d+)-(\d+)/(?:\d+|\*)$').firstMatch(value.trim());
    if (match == null || int.parse(match.group(1)!) != expectedStart) {
      throw const UpdateDownloadException('Invalid resume Content-Range');
    }
  }

  static Future<File> _completePartial(
    File partialFile,
    File finalFile,
    void Function(double progress)? onProgress,
  ) async {
    final completed = await partialFile.rename(finalFile.path);
    onProgress?.call(1);
    return completed;
  }
}

class UpdateCacheCleaner {
  const UpdateCacheCleaner._();

  static Future<void> cleanup(
    Directory cacheDirectory, {
    required Set<String> activePaths,
    int keepCompleted = 2,
  }) async {
    if (!await cacheDirectory.exists()) return;
    final active = activePaths.map(_normalizePath).toSet();
    final completed = <({File file, DateTime modified})>[];
    await for (final entity in cacheDirectory.list(followLinks: false)) {
      if (entity is! File || entity.path.endsWith('.download')) continue;
      completed.add((file: entity, modified: (await entity.stat()).modified));
    }
    completed.sort((left, right) => right.modified.compareTo(left.modified));
    for (final entry in completed.skip(keepCompleted)) {
      if (active.contains(_normalizePath(entry.file.path))) continue;
      try {
        await entry.file.delete();
      } on FileSystemException {
        // A running installer may still hold the package; retry next update.
      }
    }
  }

  /// 丢弃一次被取消的下载留下的全部中间产物:半包 `.download`、拼装中的
  /// `.assembling`,以及本资产已下好的分片(分片本身校验过,但任务作废了,
  /// 留着就是几百 MB 没人认领的垃圾)。已完整校验的成品包不动。
  static Future<void> discardAsset(
    Directory cacheDirectory,
    ResolvedUpdateAsset asset,
  ) async {
    if (!await cacheDirectory.exists()) return;
    final base = '${cacheDirectory.path}${Platform.pathSeparator}';
    final name = '${asset.sha256.toLowerCase()}-${asset.fileName}';
    final victims = <String>[
      '$base$name.download',
      '$base$name.assembling',
      for (final part in asset.parts) ...[
        '$base${part.sha256.toLowerCase()}-${part.fileName}',
        '$base${part.sha256.toLowerCase()}-${part.fileName}.download',
      ],
    ];
    for (final path in victims) {
      await _deleteQuietly(File(path));
    }
  }

  /// 启动时清理:删掉 [maxAge] 之前就没再动过的残留。断网留下的 `.download`
  /// 和分片是续传的本钱,不能立刻删;但用户如果再也不回来重试,它们会一直占着
  /// 磁盘——这里给它们一个保质期。成品包由 [cleanup] 的「留最新两个」管。
  static Future<void> sweepStale(
    Directory cacheDirectory, {
    Duration maxAge = const Duration(days: 7),
    DateTime? now,
  }) async {
    if (!await cacheDirectory.exists()) return;
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    await for (final entity in cacheDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        if ((await entity.stat()).modified.isAfter(cutoff)) continue;
      } on FileSystemException {
        continue;
      }
      await _deleteQuietly(entity);
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 安装器/杀软可能正占着文件;下一轮清理再来。
    }
  }

  static String _normalizePath(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;
}
