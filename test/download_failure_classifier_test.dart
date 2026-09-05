import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/downloads/download_failure.dart';
import 'package:dream_manga_reader/core/downloads/download_failure_classifier.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show HttpExceptionWithStatus;
import 'package:flutter_test/flutter_test.dart';

DioException _dioResponse(int status) {
  final options = RequestOptions(path: '/chapter');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<void>(requestOptions: options, statusCode: status),
  );
}

void main() {
  test('connection level errors are network failures', () {
    expect(
      classifyDownloadFailureCode(const SocketException('reset')),
      DownloadFailureCode.network,
    );
    expect(
      classifyDownloadFailureCode(TimeoutException('slow')),
      DownloadFailureCode.network,
    );
    expect(
      classifyDownloadFailureCode(
        DioException(
          requestOptions: RequestOptions(path: '/a'),
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      DownloadFailureCode.network,
    );
    expect(
      classifyDownloadFailureCode(
        DioException(
          requestOptions: RequestOptions(path: '/a'),
          error: const SocketException('reset'),
        ),
      ),
      DownloadFailureCode.network,
    );
  });

  test('http status codes pick the matching failure code', () {
    expect(
      classifyDownloadFailureCode(_dioResponse(401)),
      DownloadFailureCode.authenticationRequired,
    );
    expect(
      classifyDownloadFailureCode(_dioResponse(403)),
      DownloadFailureCode.authenticationRequired,
    );
    expect(
      classifyDownloadFailureCode(_dioResponse(404)),
      DownloadFailureCode.resourceMissing,
    );
    expect(
      classifyDownloadFailureCode(_dioResponse(429)),
      DownloadFailureCode.network,
    );
    expect(
      classifyDownloadFailureCode(_dioResponse(503)),
      DownloadFailureCode.network,
    );
    expect(
      classifyDownloadFailureCode(_dioResponse(400)),
      DownloadFailureCode.unknown,
    );
    expect(
      classifyDownloadFailureCode(
        const HttpExceptionWithStatus(404, 'missing page'),
      ),
      DownloadFailureCode.resourceMissing,
    );
  });

  test('disk full is told apart from other filesystem errors', () {
    expect(
      classifyDownloadFailureCode(
        const FileSystemException(
          'write failed',
          '/pages/0.img',
          OSError('No space left on device', 28),
        ),
      ),
      DownloadFailureCode.insufficientStorage,
    );
    expect(
      classifyDownloadFailureCode(
        const FileSystemException(
          'write failed',
          'D:/pages/0.img',
          OSError('There is not enough space on the disk', 112),
        ),
      ),
      DownloadFailureCode.insufficientStorage,
    );
    expect(
      classifyDownloadFailureCode(
        const PathNotFoundException('/sdcard/pages', OSError('missing', 2)),
      ),
      DownloadFailureCode.storageUnavailable,
    );
  });

  test('decoding errors and everything else stay separable', () {
    expect(
      classifyDownloadFailureCode(const FormatException('不支持的图片数据格式')),
      DownloadFailureCode.corruptResource,
    );
    expect(
      classifyDownloadFailureCode(StateError('no pages')),
      DownloadFailureCode.unknown,
    );
  });

  test('only transient codes are retried automatically', () {
    expect(DownloadFailureCode.network.isRetryable, isTrue);
    expect(DownloadFailureCode.sourceRefreshRequired.isRetryable, isTrue);
    for (final code in [
      DownloadFailureCode.authenticationRequired,
      DownloadFailureCode.resourceMissing,
      DownloadFailureCode.insufficientStorage,
      DownloadFailureCode.storageUnavailable,
      DownloadFailureCode.unsafePath,
      DownloadFailureCode.corruptResource,
      DownloadFailureCode.unsupportedDrm,
      DownloadFailureCode.cancelled,
      DownloadFailureCode.unknown,
    ]) {
      expect(code.isRetryable, isFalse, reason: code.name);
    }
  });

  test('classified failures carry a sanitized detail and the status', () {
    final failure = classifyDownloadFailure(
      const HttpExceptionWithStatus(
        403,
        'GET https://cdn.test/a.jpg?token=secret failed',
      ),
      retryCount: 2,
    );

    expect(failure.code, DownloadFailureCode.authenticationRequired);
    expect(failure.httpStatus, 403);
    expect(failure.retryCount, 2);
    expect(failure.detail, isNot(contains('secret')));
  });
}
