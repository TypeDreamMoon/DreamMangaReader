import 'package:dream_manga_reader/core/downloads/download_failure.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

void main() {
  test('failure round trips with a stable code', () {
    const failure = DownloadFailure(
      code: DownloadFailureCode.network,
      message: '网络连接失败',
      detail: 'connection reset',
      retryCount: 2,
      httpStatus: 503,
    );

    expect(DownloadFailure.fromJson(failure.toJson()), failure);
  });

  test('sanitizes signed URLs from persisted failure detail', () {
    final failure = DownloadFailure.fromMessage(
      DownloadFailureCode.sourceRefreshRequired,
      'GET https://cdn.test/a.ts?token=secret&expires=123#part returned 403',
    );

    expect(failure.detail, isNot(contains('secret')));
    expect(failure.detail, isNot(contains('expires')));
    expect(failure.detail, 'GET https://cdn.test/a.ts returned 403');
  });

  test('sanitizes authorization cookies and bearer tokens', () {
    final failure = DownloadFailure.fromMessage(
      DownloadFailureCode.authenticationRequired,
      'Authorization: Bearer abc.def\nCookie: session=secret',
    );

    expect(failure.detail, isNot(contains('abc.def')));
    expect(failure.detail, isNot(contains('session=secret')));
    expect(failure.detail, contains('[redacted]'));
  });

  test('task round trips a sanitized failure', () {
    final task = taskFixture().copyWith(
      state: DownloadTaskState.failed,
      failure: DownloadFailure.fromMessage(
        DownloadFailureCode.resourceMissing,
        'https://cdn.test/missing.jpg?token=secret returned 404',
        httpStatus: 404,
        retryCount: 3,
      ),
    );

    final decoded = DownloadTask.fromJson(task.toJson());
    expect(decoded, task);
    expect(decoded.failure!.detail, isNot(contains('secret')));
  });

  test('rejects unknown serialized failure codes', () {
    final json = const DownloadFailure(
      code: DownloadFailureCode.unknown,
      message: '未知错误',
      detail: 'unknown',
      retryCount: 0,
    ).toJson()
      ..['code'] = 'expired';

    expect(() => DownloadFailure.fromJson(json), throwsFormatException);
  });
}
