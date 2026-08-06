import 'dart:io';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/auth_token.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _sourceRootDefine = String.fromEnvironment('DMR_XIAOJIE_SOURCE_ROOT');
const _contentRootDefine = String.fromEnvironment('DMR_XIAOJIE_CONTENT_ROOT');
const _fixtureToken = 'fixture-token';

class _PrivateContentHttp implements HttpService {
  _PrivateContentHttp(this.contentRoot);

  final Directory contentRoot;
  final requests = <HostRequest>[];

  @override
  Future<HostResponse> fetch(HostRequest request) async {
    requests.add(request);
    final uri = Uri.parse(request.url);
    final contentsIndex = uri.pathSegments.indexOf('contents');
    if (contentsIndex < 0 || contentsIndex + 1 >= uri.pathSegments.length) {
      throw StateError('Unexpected GitHub fixture request: ${request.url}');
    }
    final segments = uri.pathSegments.sublist(contentsIndex + 1);
    if (segments.any((segment) => segment.isEmpty || segment == '..')) {
      throw StateError('Unsafe GitHub fixture path: ${request.url}');
    }
    final file = File(
      [contentRoot.path, ...segments].join(Platform.pathSeparator),
    );
    if (!file.existsSync()) {
      throw StateError('Missing private content fixture: ${file.path}');
    }
    return HostResponse(
      status: 200,
      headers: const {'content-type': 'application/json'},
      body: await file.readAsString(),
    );
  }
}

ScriptSource _loadSource(
  Directory sourceRoot,
  String scriptName,
  _PrivateContentHttp http,
) {
  return ScriptSource(
    engine: JsEngine(),
    http: http,
    scriptCode: File(
      [sourceRoot.path, scriptName].join(Platform.pathSeparator),
    ).readAsStringSync(),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final sourceRootPath = _sourceRootDefine.isNotEmpty
      ? _sourceRootDefine
      : Platform.environment['DMR_XIAOJIE_SOURCE_ROOT'] ?? '';
  final contentRootPath = _contentRootDefine.isNotEmpty
      ? _contentRootDefine
      : Platform.environment['DMR_XIAOJIE_CONTENT_ROOT'] ?? '';
  final sourceRoot = Directory(sourceRootPath);
  final contentRoot = Directory(contentRootPath);
  final skipReason = !sourceRoot.existsSync() || !contentRoot.existsSync()
      ? '未配置晓桀源仓库和内容仓库路径'
      : null;

  testWidgets('real Xiaojie scripts preserve private content headers',
      (tester) async {
    final http = _PrivateContentHttp(contentRoot);
    final novel = _loadSource(sourceRoot, 'xiaojie_novel.js', http);
    final manga = _loadSource(sourceRoot, 'xiaojie_manga.js', http);
    final anime = _loadSource(sourceRoot, 'xiaojie_anime.js', http);
    final sources = [novel, manga, anime];
    for (final source in sources) {
      SourceAuth.set(source.id, _fixtureToken);
    }
    addTearDown(() {
      for (final source in sources) {
        SourceAuth.set(source.id, null);
        source.dispose();
      }
    });

    final novels = await novel.getNovelDiscovery(1);
    final novelDetail = await novel.getNovelDetail(novels.items.single.id);
    final novelChapters = await novel.getNovelChapters(novelDetail.id);
    final document = await novel.getNovelDocument(
      novelDetail.id,
      novelChapters.items.first.id,
    );

    expect(novelDetail.title, contains('刀剑神域'));
    expect(novelChapters.items, hasLength(24));
    expect(document.resources, isNotEmpty);
    expect(
      document.resources.values.every(
        (value) => RegExp(
          r'^data:image/(png|jpeg|gif|webp);base64,',
          caseSensitive: false,
        ).hasMatch(value),
      ),
      true,
    );

    final mangaItems = await manga.getDiscovery(1);
    final mangaChapters = await manga.getChapters(mangaItems.items.single.id);
    final pages = await manga.getPages(
      mangaItems.items.single.id,
      mangaChapters.items.single.id,
    );
    expect(pages.map((page) => page.index), [0, 1, 2, 3, 4, 5]);
    expect(
      pages.every(
        (page) => page.headers?['Authorization'] == 'Bearer $_fixtureToken',
      ),
      true,
    );

    final animeItems = await anime.getDiscovery(1);
    final episodes = await anime.getChapters(animeItems.items.single.id);
    final tracks = await anime.getVideo(
      animeItems.items.single.id,
      episodes.items.single.id,
    );
    expect(tracks.single.hls, true);
    expect(tracks.single.url, endsWith('master.m3u8?ref=main'));
    expect(
      tracks.single.headers?['Authorization'],
      'Bearer $_fixtureToken',
    );

    expect(http.requests, isNotEmpty);
    expect(
      http.requests.every(
        (request) =>
            request.headers['Authorization'] == 'Bearer $_fixtureToken' &&
            request.headers['Accept'] ==
                'application/vnd.github.raw+json',
      ),
      true,
    );
  }, skip: skipReason != null);
}
