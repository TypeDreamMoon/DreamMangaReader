import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';
const _kotlinRoot = 'android/app/src/main/kotlin/com/dreammoon/dream_manga_reader';

String _source(String path) => File('$_kotlinRoot/$path').readAsStringSync();

void main() {
  test('screenshots land in DCIM through MediaStore', () {
    final source = _source('gallery/GalleryBridge.kt');

    expect(source, contains('dream_manga_reader/gallery'));
    // 相册看得到的落点,不是那串 /Android/data/<包名>/files。
    expect(source, contains('Environment.DIRECTORY_DCIM'));
    expect(source, contains('private const val ALBUM = "ScreenShot"'));
    expect(source, contains('MediaStore.Images.Media.RELATIVE_PATH'));
    expect(source, contains('MediaStore.Images.Media.EXTERNAL_CONTENT_URI'));
    // 写完之前对相册不可见,免得扫描器抓到半个文件。
    expect(source, contains('MediaStore.Images.Media.IS_PENDING'));
  });

  test('the legacy path is the only one that asks for storage', () {
    final source = _source('gallery/GalleryBridge.kt');

    // Android 10 起 MediaStore 自己管权限;权限只在 Q 以下才请求。
    expect(source, contains('Build.VERSION.SDK_INT < Build.VERSION_CODES.Q'));
    expect(source, contains('Manifest.permission.WRITE_EXTERNAL_STORAGE'));
    // 老系统没有 MediaStore 代劳,不扫一遍相册里就是不出现。
    expect(source, contains('MediaScannerConnection.scanFile'));

    final manifest = XmlDocument.parse(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final write = manifest.findAllElements('uses-permission').singleWhere(
          (element) =>
              element.getAttribute('name', namespace: _android) ==
              'android.permission.WRITE_EXTERNAL_STORAGE',
        );
    // 钉死上限,否则新系统的权限列表里会白白多出一条存储权限。
    expect(write.getAttribute('maxSdkVersion', namespace: _android), '28');
  });

  test('MainActivity owns the bridge for its whole lifetime', () {
    final source = _source('MainActivity.kt');

    expect(source, contains('galleryBridge = GalleryBridge(this)'));
    expect(source, contains('galleryBridge?.onRequestPermissionsResult('));
    expect(source, contains('galleryBridge?.dispose()'));
  });
}
