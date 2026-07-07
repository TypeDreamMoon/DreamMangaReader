import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/features/reader/reader_page.dart';

/// 验证**无缝接章**:起始章接近末尾时自动加载并接上下一章(扁平列表拼接)。
/// 用 onDebugFlat 钩子直接观测(已加载章节数, 扁平总页数),不依赖滚动手势。
/// 运行:flutter test integration_test/reader_seamless_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reaching a chapter end auto-appends the next chapter',
      (tester) async {
    SharedPreferences.setMockInitialValues({'lib.readerMode': 'webtoon'});
    final store = LibraryStore();
    await store.load();

    const chapters = [
      Chapter(id: 'c0', name: '第1话'),
      Chapter(id: 'c1', name: '第2话'),
      Chapter(id: 'c2', name: '第3话'),
    ];
    final source = _FakeSource({
      'c0': [_pg(0), _pg(1), _pg(2)], // 3 页(起始即接近末尾 → 触发接上 c1)
      'c1': [_pg(3), _pg(4)], // 2 页
      'c2': [_pg(5)],
    });

    var loadedChapters = 0;
    var flatPages = 0;
    await tester.pumpWidget(
      LibraryScope(
        store: store,
        child: MaterialApp(
          home: ReaderPage(
            source: source,
            manga: const Manga(id: 'm', title: 'T'),
            chapters: chapters,
            index: 0,
            onDebugFlat: (c, f) {
              loadedChapters = c;
              flatPages = f;
            },
          ),
        ),
      ),
    );
    // 用固定 pump 而非 pumpAndSettle:加载占位是无限流光动画,pumpAndSettle 永不返回。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    // c0(3 页,_curFlat=0 已在 length-3 处)→ 自动接上 c1。共 2 章 5 页。
    expect(loadedChapters, 2);
    expect(flatPages, 5);
    // 起始章名可见
    expect(find.text('第1话'), findsOneWidget);

    store.dispose();
  });

  testWidgets('single/last chapter does not append', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();

    const chapters = [Chapter(id: 'only', name: '第1话')];
    final source = _FakeSource({
      'only': [_pg(0), _pg(1), _pg(2), _pg(3), _pg(4)],
    });
    var loadedChapters = 0;
    await tester.pumpWidget(
      LibraryScope(
        store: store,
        child: MaterialApp(
          home: ReaderPage(
            source: source,
            manga: const Manga(id: 'm', title: 'T'),
            chapters: chapters,
            index: 0,
            onDebugFlat: (c, f) => loadedChapters = c,
          ),
        ),
      ),
    );
    // 用固定 pump 而非 pumpAndSettle:加载占位是无限流光动画,pumpAndSettle 永不返回。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(loadedChapters, 1); // 唯一/最后一章:无下一章可接
    store.dispose();
  });
}

PageImage _pg(int i) => PageImage(index: i, url: 'x://p/$i.jpg');

class _FakeSource implements MangaSource {
  _FakeSource(this.byChapter);
  final Map<String, List<PageImage>> byChapter;

  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) async =>
      byChapter[chapterId] ?? const [];

  @override
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) async =>
      const [];

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
