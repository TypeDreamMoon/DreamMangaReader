// 发现页:内容类型的展示名必须走 l10n(枚举里塞中文会漏进英文/日文界面),
// 以及分页失败重试成功后错误态要跟着消失。
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/source_controller.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/discovery/discovery_page.dart';
import 'package:dream_manga_reader/features/discovery/recommend_controller.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 发现页最小可跑环境。不注册任何源 → 混合模式没有游标,页面不会联网。
class _DiscoveryFixture {
  _DiscoveryFixture(this.library, this.sources, this.recs);

  final LibraryStore library;
  final SourceController sources;
  final RecommendController recs;

  static Future<_DiscoveryFixture> create() async {
    SharedPreferences.setMockInitialValues(const {});
    registeredSources = [];
    final library = LibraryStore();
    await library.load();
    final sources = SourceController();
    await sources.load();
    return _DiscoveryFixture(library, sources, RecommendController());
  }

  Widget host(Locale locale) => MaterialApp(
        theme: buildTheme(AppThemeVariant.light),
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: LibraryScope(
          store: library,
          child: SourceScope(
            controller: sources,
            child: DiscoveryPage(recommendController: recs),
          ),
        ),
      );

  void dispose() {
    library.dispose();
    sources.dispose();
    recs.dispose();
  }
}


const _srcMeta = SourceMeta(id: 'src', name: '测试源', script: '');

/// 发现流:第一页照常给,第二页先失败一次、再重试就成功。
class _FlakySource implements MangaSource {
  int discoveryCalls = 0;
  bool failNextPage = true;

  @override
  Future<Paged<Manga>> getDiscovery(int page,
      {Map<String, Object?>? filters}) async {
    discoveryCalls++;
    if (page > 1) {
      if (failNextPage) {
        failNextPage = false;
        throw StateError('这一页翻车了');
      }
      // 重试成功但这一页真的没内容了 —— 页脚该从「加载失败」变成「没有更多了」。
      return const Paged<Manga>([], hasNext: false);
    }
    return Paged<Manga>(
      [for (var i = 0; i < 24; i++) Manga(id: 'p1-$i', title: '第一页 $i')],
      hasNext: true,
    );
  }

  @override
  String get id => _srcMeta.id;
  @override
  String get name => _srcMeta.name;
  @override
  String get lang => 'zh';
  @override
  String get baseUrl => 'https://example.test';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;
  @override
  List<FilterDef> get filters => const [];
  @override
  List<SourceSection> get sections => const [];

  @override
  Future<Paged<Manga>> getSearch(String query, int page,
          {Map<String, Object?>? filters}) =>
      throw UnimplementedError();
  @override
  Future<Paged<Manga>> getSection(String sectionId, int page) =>
      throw UnimplementedError();
  @override
  Future<Manga> getMangaDetail(String mangaId) => throw UnimplementedError();
  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) =>
      throw UnimplementedError();
  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) =>
      throw UnimplementedError();
  @override
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) =>
      throw UnimplementedError();
  @override
  Future<SourceLogin> login(String username, String password) =>
      throw UnimplementedError();
  @override
  void dispose() {}
}

void main() {
  tearDown(() {
    registeredSources = [];
  });

  testWidgets('英文界面下内容类型 tab 不出现中文', (tester) async {
    final fixture = await _DiscoveryFixture.create();
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(const Locale('en')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Manga'), findsWidgets);
    expect(find.text('Anime'), findsWidgets);
    expect(find.text('Novels'), findsWidgets);
    // 枚举里的中文字面量以前会直接顶到 tab 上。
    expect(find.text('漫画'), findsNothing);
    expect(find.text('番剧'), findsNothing);
    expect(find.text('小说'), findsNothing);
  });

  testWidgets('搜索提示按当前语言给出内容类型名', (tester) async {
    final fixture = await _DiscoveryFixture.create();
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(const Locale('en')));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Novels').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Search titles · Novels'), findsOneWidget);
    expect(find.text('Search titles · 小说'), findsNothing);
  });

  testWidgets('翻页失败后重试成功,页脚的「加载失败」跟着消失', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    registeredSources = const [_srcMeta];
    final library = LibraryStore();
    await library.load();
    addTearDown(library.dispose);
    library.showSourcePicker = true; // 单源模式(不走混合)
    final sources = SourceController(_srcMeta);
    await sources.load();
    addTearDown(sources.dispose);
    final recs = RecommendController();
    addTearDown(recs.dispose);
    final source = _FlakySource();

    await tester.binding.setSurfaceSize(const Size(420, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: library,
        child: SourceScope(
          controller: sources,
          child: DiscoveryPage(
            recommendController: recs,
            sourceBuilder: (_) => source,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('第一页 0'), findsOneWidget);

    // 滚到底触发第二页 → 失败,页脚换成「加载失败,重试」。
    await tester.dragFrom(const Offset(210, 400), const Offset(0, -4000));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('加载失败,重试'), findsOneWidget);
    expect(source.discoveryCalls, 2);

    // 往回滚一点再滚到底 = 重试这一页,这次成功。
    await tester.dragFrom(const Offset(210, 400), const Offset(0, 600));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.dragFrom(const Offset(210, 400), const Offset(0, -900));
    await tester.pump(const Duration(milliseconds: 400));

    expect(source.discoveryCalls, 3, reason: '重试确实发出去了');
    expect(find.text('加载失败,重试'), findsNothing,
        reason: '这一页已经成功了,错误态只清在 _reset 里是不够的');
    expect(find.text('没有更多了'), findsOneWidget);
  });
}
