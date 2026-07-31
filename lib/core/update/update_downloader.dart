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
    await cache.create(recursive: true);
    final finalFile = File(
      '${cache.path}${Platform.pathSeparator}${asset.fileName}',
    );
    final partialFile = File('${finalFile.path}.download');

    if (await finalFile.exists()) {
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
    }

    var partialLength =
        await partialFile.exists() ? await partialFile.length() : 0;
    if (partialLength >= asset.sizeBytes) {
      await UpdateFileVerifier.verify(
        partialFile,
        expectedSize: asset.sizeBytes,
        expectedSha256: asset.sha256,
      );
      return _completeDownload(
        partialFile,
        finalFile,
        cache,
        activePaths: activePaths,
        onProgress: onProgress,
      );
    }

    final requestedResume = partialLength > 0;
    final response = await _dio.get<ResponseBody>(
      asset.url,
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
        onProgress?.call((received / asset.sizeBytes).clamp(0, 1));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    await UpdateFileVerifier.verify(
      partialFile,
      expectedSize: asset.sizeBytes,
      expectedSha256: asset.sha256,
    );
    return _completeDownload(
      partialFile,
      finalFile,
      cache,
      activePaths: activePaths,
      onProgress: onProgress,
    );
  }

  Future<Directory> _resolveCacheDirectory() async {
    final configured = cacheDirectory;
    if (configured != null) return configured;
    final temp = await getTemporaryDirectory();
    return Directory(
      '${temp.path}${Platform.pathSeparator}dream_manga_reader_updates',
    );
  }

  static void _validateContentRange(Headers headers, int expectedStart) {
    final value = headers.value('content-range');
    final match = value == null
        ? null
        : RegExp(r'^bytes (\d+)-\d+/\d+$').firstMatch(value);
    if (match == null || int.parse(match.group(1)!) != expectedStart) {
      throw const UpdateDownloadException('Invalid resume Content-Range');
    }
  }

  static Future<File> _completeDownload(
    File partialFile,
    File finalFile,
    Directory cache, {
    required Set<String> activePaths,
    required void Function(double progress)? onProgress,
  }) async {
    final completed = await partialFile.rename(finalFile.path);
    onProgress?.call(1);
    await UpdateCacheCleaner.cleanup(
      cache,
      activePaths: {...activePaths, completed.path},
    );
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

  static String _normalizePath(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;
}
