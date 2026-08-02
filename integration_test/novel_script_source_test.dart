import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/source.dart';

/// 验证小说源的 prepare/handle 桥接在真机上跑通:ScriptSource 复用漫画那套 JS
/// 入口(prepareSearch/handleSearch、prepareChapter/handleChapter …),但要按小说
/// 的形状解码——章节带卷信息,正文带 format/baseUrl/resources。
///
/// 必须放在 integration_test:JsEngine 走 flutter_js 的 QuickJS 原生库,
/// 纯 `flutter test`(Dart VM)不加载插件原生代码,会以 error code 126 失败。
/// 运行:flutter test integration_test/novel_script_source_test.dart -d windows
class _FakeHttp implements HttpService {
  @override
  Future<HostResponse> fetch(HostRequest request) async => const HostResponse(
        status: 200,
        headers: {},
        body: '{"ok":true}',
      );
}

const _novelFixtureScript = r'''
var __source = {
  meta: {
    id: 'novel-fixture',
    name: 'Novel Fixture',
    lang: 'zh-Hans',
    baseUrl: 'https://example.test'
  },
  prepareDiscovery(page, filters) { return { url: 'https://example.test' }; },
  handleDiscovery(text) {
    return [{ id: 'n1', title: '测试小说', status: 'ongoing' }];
  },
  prepareSection(sectionId, page) { return { url: 'https://example.test' }; },
  prepareSearch(query, page, filters) { return { url: 'https://example.test' }; },
  handleSearch(text) {
    return [{ id: 'n1', title: '测试小说', authors: ['作者'] }];
  },
  prepareMangaInfo(novelId) { return { url: 'https://example.test' }; },
  handleMangaInfo(text, novelId) {
    return { id: novelId, title: '测试小说', status: 'completed' };
  },
  prepareChapterList(novelId, page) { return { url: 'https://example.test' }; },
  handleChapterList(text, novelId, page) {
    return [{
      id: 'c1',
      title: '第一章',
      number: 1,
      volumeId: 'v1',
      volumeTitle: '第一卷'
    }];
  },
  prepareChapter(novelId, chapterId) { return { url: 'https://example.test' }; },
  handleChapter(text, novelId, chapterId) {
    return {
      format: 'html',
      content: '<p>正文</p>',
      baseUrl: 'https://example.test/books/n1/',
      resources: { 'cover.jpg': 'https://example.test/cover.jpg' }
    };
  }
};
''';

const _malformedChapterScript = r'''
var __source = {
  meta: {
    id: 'novel-malformed',
    name: 'Malformed Novel',
    lang: 'zh-Hans',
    baseUrl: 'https://example.test'
  },
  prepareChapter(novelId, chapterId) { return { url: 'https://example.test' }; },
  handleChapter(text, novelId, chapterId) {
    return { format: 'html', baseUrl: 'https://example.test/' };
  }
};
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('novel script decodes search, chapters and HTML document',
      (tester) async {
    final source = ScriptSource(
      engine: JsEngine(),
      http: _FakeHttp(),
      scriptCode: _novelFixtureScript,
    );
    addTearDown(source.dispose);

    final novels = await source.getNovelSearch('测试', 1);
    final chapters = await source.getNovelChapters('n1');
    final document = await source.getNovelDocument('n1', 'c1');

    expect(novels.items.single.title, '测试小说');
    expect(chapters.items.single.volumeTitle, '第一卷');
    expect(document.format, NovelDocumentFormat.html);
    expect(document.content, contains('<p>'));
    expect(document.resources['cover.jpg'], contains('cover.jpg'));
  });

  testWidgets('a chapter without content fails as a format error',
      (tester) async {
    // 源脚本是用户可安装的(zip 导入 / 私有源仓),畸形返回值必须走已有的错误
    // 处理路径,而不是以裸 TypeError 崩掉。
    final source = ScriptSource(
      engine: JsEngine(),
      http: _FakeHttp(),
      scriptCode: _malformedChapterScript,
    );
    addTearDown(source.dispose);

    await expectLater(
      source.getNovelDocument('n1', 'c1'),
      throwsA(isA<FormatException>()),
    );
  });
}
