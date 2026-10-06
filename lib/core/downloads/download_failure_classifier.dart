import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show HttpExceptionWithStatus;

import 'download_failure.dart';

/// 把执行器抛出的异常归到 [DownloadFailureCode]。
///
/// 之前所有异常一律记成 `unknown`,失败任务既看不出原因、也没法判断该不该自动
/// 重试。分类只看异常类型与 HTTP 状态码,不解析文案(文案会随源/语言变)。
DownloadFailureCode classifyDownloadFailureCode(Object error) {
  final status = downloadFailureHttpStatus(error);
  if (status != null) return _codeForHttpStatus(status);
  return _codeForError(error);
}

/// 异常里能取到的 HTTP 状态码(取不到返回 null)。
int? downloadFailureHttpStatus(Object error) {
  if (error is HttpExceptionWithStatus) return error.statusCode;
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null) return status;
    final inner = error.error;
    return inner == null ? null : downloadFailureHttpStatus(inner);
  }
  return null;
}

/// 分类并生成一条可持久化的失败记录([detail] 已脱敏)。
DownloadFailure classifyDownloadFailure(Object error, {int retryCount = 0}) {
  return DownloadFailure.fromDetail(
    classifyDownloadFailureCode(error),
    error.toString(),
    retryCount: retryCount,
    httpStatus: downloadFailureHttpStatus(error),
  );
}

DownloadFailureCode _codeForHttpStatus(int status) => switch (status) {
      401 || 403 || 407 => DownloadFailureCode.authenticationRequired,
      404 || 410 => DownloadFailureCode.resourceMissing,
      // 限流、超时与服务端错误都是暂时的,交给自动重试。
      408 || 425 || 429 => DownloadFailureCode.network,
      >= 500 => DownloadFailureCode.network,
      // 其它 4xx 是请求本身有问题,重试没有意义。
      _ => DownloadFailureCode.unknown,
    };

DownloadFailureCode _codeForError(Object error) {
  if (error is DioException) return _codeForDioException(error);
  if (error is SocketException ||
      error is HttpException ||
      error is TlsException ||
      error is TimeoutException ||
      error is WebSocketException) {
    return DownloadFailureCode.network;
  }
  if (error is FileSystemException) return _codeForFileSystemException(error);
  // 图片/文档解码失败:拿到的字节不是能用的内容。
  if (error is FormatException) return DownloadFailureCode.corruptResource;
  return DownloadFailureCode.unknown;
}

DownloadFailureCode _codeForDioException(DioException error) {
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.connectionError ||
    DioExceptionType.badCertificate ||
    DioExceptionType.transformTimeout =>
      DownloadFailureCode.network,
    DioExceptionType.cancel => DownloadFailureCode.cancelled,
    DioExceptionType.badResponse => DownloadFailureCode.unknown,
    DioExceptionType.unknown => _codeForUnknownDioException(error),
  };
}

DownloadFailureCode _codeForUnknownDioException(DioException error) {
  final inner = error.error;
  if (inner == null) return DownloadFailureCode.network;
  final code = _codeForError(inner);
  // dio 的 unknown 多半包着 SocketException 之类的传输异常。
  return code == DownloadFailureCode.unknown
      ? DownloadFailureCode.network
      : code;
}

// ENOSPC(POSIX)与 ERROR_DISK_FULL / ERROR_HANDLE_DISK_FULL(Windows)。
const _diskFullErrorCodes = {28, 39, 112};

DownloadFailureCode _codeForFileSystemException(FileSystemException error) {
  final osError = error.osError;
  if (osError != null && _diskFullErrorCodes.contains(osError.errorCode)) {
    return DownloadFailureCode.insufficientStorage;
  }
  final message = '${error.message} ${osError?.message ?? ''}'.toLowerCase();
  if (message.contains('no space') || message.contains('disk is full')) {
    return DownloadFailureCode.insufficientStorage;
  }
  return DownloadFailureCode.storageUnavailable;
}
