import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHttp implements HttpService {
  @override
  Future<HostResponse> fetch(HostRequest request) async => const HostResponse(
        status: 200,
        headers: {},
        body: '{"ok":true}',
      );
}

const novelFixtureScript = r'''
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('novel source builder rejects non-novel metadata', () {
    const manga = SourceMeta(id: 'm', name: 'Manga', script: '');

    expect(() => buildNovelSource(manga), throwsArgumentError);
  });

  test('novel script decodes search, chapters and HTML document', () async {
    final source = ScriptSource(
      engine: JsEngine(),
      http: FakeHttp(),
      scriptCode: novelFixtureScript,
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
}
