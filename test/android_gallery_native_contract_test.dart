import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';
const _kotlinRoot = 'android/app/src/main/kotlin/com/dreammoon/dream_manga_reader';

String _source(String path) => File('$_kotlinRoot/$path').readAsStringSync();

/// 切出某个成员函数的正文(靠 4 空格缩进的收尾大括号定界),好把断言钉在这个函数里。
String _body(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: '找不到 $signature');
  final end = source.indexOf('\n    }', start);
  expect(end, isNonNegative, reason: '$signature 没有收尾');
  return source.substring(start, end);
}

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

  test('a second save queues up instead of evicting the first', () {
    final source = _source('gallery/GalleryBridge.kt');

    // 单槽 pendingSave 会被下一次 saveImage 覆盖:前一个 Result 再没人回调,
    // Dart 侧的 future 就永远挂着。等权限的保存必须排队。
    expect(source, isNot(contains('var pendingSave')));
    expect(source, contains('private val pendingSaves = ArrayDeque'));
    expect(source, contains('pendingSaves.addLast('));
    // 弹窗只由第一笔发起,其余搭同一次权限结果的车。
    expect(source, contains('if (pendingSaves.size == 1)'));

    final answered = _body(source, 'fun onRequestPermissionsResult(');
    expect(answered, contains('while (pendingSaves.isNotEmpty())'));
    expect(answered, contains('pendingSaves.removeFirst()'));
    expect(answered, contains('complete(image, result)'));
    expect(answered, contains('"permission_denied"'));
  });

  test('nothing is left hanging when the bridge goes away', () {
    final source = _source('gallery/GalleryBridge.kt');

    // dispose 直接丢掉队列 = 那些 Result 永不回调。走之前逐个回一个错误。
    final disposed = _body(source, 'fun dispose()');
    expect(disposed, contains('while (pendingSaves.isNotEmpty())'));
    expect(disposed, contains('pendingSaves.removeFirst()'));
    expect(disposed, contains('"cancelled"'));
  });

  test('MainActivity owns the bridge for its whole lifetime', () {
    final source = _source('MainActivity.kt');

    expect(source, contains('galleryBridge = GalleryBridge(this)'));
    expect(source, contains('galleryBridge?.onRequestPermissionsResult('));
    expect(source, contains('galleryBridge?.dispose()'));
  });
}
