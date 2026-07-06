import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/source.dart';

/// 验证 host-native HTML 解析(Dart package:html 经 host.html.* 暴露给 JS)
/// 在真机上跑通:JS 源用 host.html 解析 fixture HTML 抽出列表。
///
/// 运行:flutter test integration_test/html_source_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('JS source parses HTML via host.html.* on this platform',
      (tester) async {
    final engine = JsEngine();
    addTearDown(engine.dispose);

    final src = ScriptSource(
      engine: engine,
      http: _FixtureHttp(),
      scriptCode: _htmlSourceJs,
    );

    final page = await src.getDiscovery(1);

    expect(page.items.length, 3);
    expect(page.items[0].id, '/comic/1');
    expect(page.items[0].title, '墨染之约');
    expect(page.items[1].title, '银河剑客');
    expect(page.items[2].id, '/comic/3');
    expect(page.items[2].title, '雾之国');

    // 再跑一次以确认节点 id 表 reset 后仍正确(不串号)
    final again = await src.getDiscovery(1);
    expect(again.items.first.title, '墨染之约');
  });
}

class _FixtureHttp implements HttpService {
  @override
  Future<HostResponse> fetch(HostRequest request) async => HostResponse(
        status: 200,
        headers: const {},
        body: '''
<html><body>
  <ul class="book-list">
    <li class="book"><a href="/comic/1" title="墨染之约">墨染之约</a></li>
    <li class="book"><a href="/comic/2" title="银河剑客">银河剑客</a></li>
    <li class="book"><a href="/comic/3" title="雾之国">雾之国</a></li>
  </ul>
</body></html>
''',
      );
}

const String _htmlSourceJs = r'''
var __source = {
  meta: { id: 'htmldemo', name: 'HTML Demo 源', lang: 'zh-Hans',
          baseUrl: 'https://demo.test', version: 1, nsfw: false },
  prepareDiscovery: function (page) {
    return { url: this.meta.baseUrl + '/list?p=' + page };
  },
  handleDiscovery: function (text) {
    var doc = host.html.parse(text);
    var links = host.html.select(doc, 'ul.book-list li.book a');
    return links.map(function (a) {
      return { id: host.html.attr(a, 'href'), title: host.html.text(a) };
    });
  }
};
''';
