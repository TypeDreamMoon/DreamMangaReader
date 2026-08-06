import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';
const _kotlinRoot =
    'android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/update';

String _source(String name) => File('$_kotlinRoot/$name').readAsStringSync();

void main() {
  test('Android declares a private data-sync update service', () {
    final manifest = XmlDocument.parse(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final permissions = manifest.findAllElements('uses-permission').map(
          (element) => element.getAttribute('name', namespace: _android),
        );
    expect(
      permissions,
      containsAll({
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
        'android.permission.WAKE_LOCK',
      }),
    );

    final service = manifest.findAllElements('service').singleWhere(
          (element) => element
              .getAttribute('name', namespace: _android)!
              .endsWith('UpdateDownloadService'),
        );
    expect(service.getAttribute('exported', namespace: _android), 'false');
    expect(
      service.getAttribute('foregroundServiceType', namespace: _android),
      'dataSync',
    );
    expect(service.getAttribute('stopWithTask', namespace: _android), 'false');
  });

  test('FileProvider exposes only the private updates directory', () {
    final manifest = XmlDocument.parse(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final provider = manifest.findAllElements('provider').singleWhere(
          (element) =>
              element.getAttribute('name', namespace: _android) ==
              'androidx.core.content.FileProvider',
        );
    expect(provider.getAttribute('exported', namespace: _android), 'false');
    expect(
      provider.getAttribute('grantUriPermissions', namespace: _android),
      'true',
    );

    final paths = XmlDocument.parse(
      File('android/app/src/main/res/xml/update_file_paths.xml')
          .readAsStringSync(),
    );
    expect(paths.rootElement.children.whereType<XmlElement>().length, 1);
    final filesPath = paths.findAllElements('files-path').single;
    expect(filesPath.getAttribute('path'), 'updates/');
  });

  test('native bridge exposes the complete Flutter contract', () {
    final source = _source('UpdateDownloadBridge.kt');
    for (final method in [
      'startUpdateDownload',
      'cancelUpdateDownload',
      'getUpdateDownloadState',
      'installReadyUpdate',
    ]) {
      expect(source, contains('"$method"'));
    }
    expect(source, contains('POST_NOTIFICATIONS'));
    expect(source, contains('FileProvider.getUriForFile'));
    expect(source, contains('registerReceiver'));
    expect(source, contains('RECEIVER_NOT_EXPORTED'));
  });

  test('download service retains resumable files and protects signed URLs', () {
    final source = _source('UpdateDownloadService.kt');
    for (final contract in [
      'START_REDELIVER_INTENT',
      'Range',
      'Content-Range',
      'MAX_ATTEMPTS = 3',
      'expired_url',
      '.download',
      '.assembling',
      'GET_SIGNING_CERTIFICATES',
      'SHA-256',
      'PARTIAL_WAKE_LOCK',
      'FOREGROUND_SERVICE_TYPE_DATA_SYNC',
    ]) {
      expect(source, contains(contract));
    }
    expect(source, isNot(contains('Log.d(')));
    expect(source, isNot(contains('Log.e(')));
  });

  test('native persisted state never contains remote URLs', () {
    final source = _source('UpdateDownloadState.kt');
    expect(source, contains('toJson'));
    expect(source, isNot(contains('"url"')));
    expect(source, isNot(contains('token')));
  });
}
