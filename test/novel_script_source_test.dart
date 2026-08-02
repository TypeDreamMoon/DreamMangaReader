import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只放不依赖 JS 引擎的用例。真正跑脚本的那部分在
/// integration_test/novel_script_source_test.dart —— JsEngine 需要 flutter_js
/// 的 QuickJS 原生库,纯 `flutter test` 加载不到插件原生代码。
void main() {
  test('novel source builder rejects non-novel metadata', () {
    const manga = SourceMeta(id: 'm', name: 'Manga', script: '');

    expect(() => buildNovelSource(manga), throwsArgumentError);
  });

  test('manga source builder rejects novel metadata', () {
    const novel = SourceMeta(id: 'n', name: 'Novel', script: '', kind: 'novel');

    expect(() => buildSource(novel), throwsArgumentError);
  });
}
