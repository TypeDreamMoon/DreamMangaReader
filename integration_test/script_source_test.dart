import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/source.dart';

/// 验证 JS↔宿主 的 prepare/handle 桥接在真机上跑通:
/// JS 构造请求 → 宿主(Fake)返回响应 → JS 解析 → Dart 拿到结构化数据。
///
/// 用 Fake HttpService 保持确定性(真实 dio I/O 已由过盾页/集成另证)。
/// 运行:flutter test integration_test/script_source_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ScriptSource prepare/handle round-trips across the JS boundary',
      (tester) async {
    final engine = JsEngine();
    addTearDown(engine.dispose);
    final http = _FakeHttp();

    final src = ScriptSource(
      engine: engine,
      http: http,
      scriptCode: _demoSourceJs,
    );

    // 元数据由 JS 读出
    expect(src.id, 'demo');
    expect(src.name, 'Demo 源');
    expect(src.baseUrl, 'https://demo.test');

    final page = await src.getDiscovery(1);

    // JS 的 prepare 构造的请求被宿主收到(URL + header)
    expect(http.last!.url, 'https://demo.test/api/list?page=1');
    expect(http.last!.headers['X-Test'], 'demo');

    // JS 的 handle 解析后的结构化数据回到 Dart(含中文)
    expect(page.items.length, 2);
    expect(page.items.first.id, '1');
    expect(page.items.first.title, '墨染之约');
    expect(page.items.first.authors, ['青行灯']);
    expect(page.items.first.genres, ['奇幻']);
    expect(page.items[1].title, '银河剑客');
  });
}

class _FakeHttp implements HttpService {
  HostRequest? last;

  @override
  Future<HostResponse> fetch(HostRequest request) async {
    last = request;
    return HostResponse(
      status: 200,
      headers: const {},
      body: '{"items":['
          '{"id":1,"name":"墨染之约","author":"青行灯","tags":["奇幻"]},'
          '{"id":2,"name":"银河剑客","author":"甲","tags":["科幻"]}'
          ']}',
    );
  }
}

const String _demoSourceJs = r'''
var __source = {
  meta: { id: 'demo', name: 'Demo 源', lang: 'zh-Hans',
          baseUrl: 'https://demo.test', version: 1, nsfw: false },
  prepareDiscovery: function (page, filters) {
    return {
      url: this.meta.baseUrl + '/api/list?page=' + page,
      method: 'GET',
      headers: { 'X-Test': 'demo' }
    };
  },
  handleDiscovery: function (text) {
    var data = JSON.parse(text);
    return data.items.map(function (it) {
      return { id: String(it.id), title: it.name, authors: [it.author], genres: it.tags };
    });
  }
};
''';
