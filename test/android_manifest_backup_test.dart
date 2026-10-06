import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';

void main() {
  test('Android never backs the app data up', () {
    // 不声明 allowBackup 等于 true:SharedPreferences 整个目录会进 Google 云备份,
    // 也能被 `adb backup` 拉走。那里面有 WebDAV 同步账密、翻译 LLM 的 API Key、
    // 各源登录 token。
    final manifest = XmlDocument.parse(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final application = manifest.findAllElements('application').single;
    expect(
      application.getAttribute('allowBackup', namespace: _android),
      'false',
      reason: 'application 上必须显式 android:allowBackup="false"',
    );
  });
}
