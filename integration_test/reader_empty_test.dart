import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/features/reader/reader_page.dart';

/// 回归:空章节(getPages 返回 [])在 **webtoon 模式**下
/// (1) 不得崩溃(旧 bug:initialScrollIndex 的 0.clamp(0,-1) 抛 ArgumentError);
/// (2) 应自动退回上一页,不把用户困在无返回键的黑屏。
/// 运行:flutter test integration_test/reader_empty_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty pages in webtoon mode: no crash, auto-returns',
      (tester) async {
    SharedPreferences.setMockInitialValues({'lib.readerMode': 'webtoon'});
    final store = LibraryStore();
    await store.load();
    expect(store.readerMode, ReaderMode.webtoon);

    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      LibraryScope(
        store: store,
        child: MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: Center(child: Text('DETAIL'))),
        ),
      ),
    );

    // 从 DETAIL 进入阅读器
    nav.currentState!.push(MaterialPageRoute(
      builder: (_) => ReaderPage(
        source: _FakeSource(const []),
        manga: const Manga(id: 'm', title: 'T'),
        chapters: const [Chapter(id: 'c', name: '第1话')],
        index: 0,
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull); // 不崩溃
    expect(find.text('DETAIL'), findsOneWidget); // 已自动退回

    store.dispose();
  });
}

/// 最小假源:getPages 返回预设列表,其余方法未用。
class _FakeSource implements MangaSource {
  _FakeSource(this.pages);
  final List<PageImage> pages;

  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  String get lang => 'zh';
  @override
  String get baseUrl => '';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;
  @override
  List<FilterDef> get filters => const [];
  @override
  List<SourceSection> get sections => const [];
  @override
  Future<Paged<Manga>> getSection(String sectionId, int page) async =>
      const Paged<Manga>([]);

  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) async =>
      pages;

  @override
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) async =>
      const [];

  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) async =>
      const Paged([]);
  @override
  Future<Manga> getMangaDetail(String mangaId) async =>
      const Manga(id: 'm', title: 'T');
  @override
  Future<Paged<Manga>> getDiscovery(int page,
          {Map<String, Object?>? filters}) async =>
      const Paged([]);
  @override
  Future<Paged<Manga>> getSearch(String query, int page,
          {Map<String, Object?>? filters}) async =>
      const Paged([]);
  @override
  Future<SourceLogin> login(String username, String password) async =>
      throw UnsupportedError('n/a');
  @override
  void dispose() {}
}
