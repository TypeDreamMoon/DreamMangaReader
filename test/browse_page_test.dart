// 站点板块浏览页:在途切板块不能把页面卡在「转圈」上。
//
// 旧实现里换板块直接 _reload(),而 _loading 还被上一轮请求占着 → 新一轮进不去;
// 旧请求回来时板块 id 已经对不上,提前 return 也不复位 → 永久转圈。
import 'dart:async';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/discovery/browse_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _meta = SourceMeta(id: 'src', name: '测试源', script: '');

/// 每次 getSection 都挂在一个 Completer 上,测试自己决定谁先回来。
class _GatedSource implements MangaSource {
  final List<({String sectionId, int page, Completer<Paged<Manga>> gate})> calls =
      [];
  bool disposed = false;

  @override
  List<SourceSection> get sections => const [
        SourceSection(id: 'a', name: '板块 A'),
        SourceSection(id: 'b', name: '板块 B'),
      ];

  @override
  Future<Paged<Manga>> getSection(String sectionId, int page) {
    final gate = Completer<Paged<Manga>>();
    calls.add((sectionId: sectionId, page: page, gate: gate));
    return gate.future;
  }

  @override
  String get id => _meta.id;
  @override
  String get name => _meta.name;
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
  Future<Paged<Manga>> getDiscovery(int page,
          {Map<String, Object?>? filters}) =>
      throw UnimplementedError();
  @override
  Future<Paged<Manga>> getSearch(String query, int page,
          {Map<String, Object?>? filters}) =>
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
  void dispose() => disposed = true;
}

Paged<Manga> _page(String prefix) => Paged<Manga>(
      [for (var i = 1; i <= 2; i++) Manga(id: '$prefix$i', title: '$prefix$i')],
      hasNext: false,
    );

Future<Widget> _host(_GatedSource source) async {
  SharedPreferences.setMockInitialValues(const {});
  final library = LibraryStore();
  await library.load();
  addTearDown(library.dispose);
  return MaterialApp(
    theme: buildTheme(AppThemeVariant.light),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: LibraryScope(
      store: library,
      child: BrowsePage(meta: _meta, sourceBuilder: (_) => source),
    ),
  );
}

void main() {
  testWidgets('在途切板块:旧请求回来后不再卡住新一轮', (tester) async {
    final source = _GatedSource();
    await tester.pumpWidget(await _host(source));
    await tester.pump();

    expect(source.calls, hasLength(1));
    expect(source.calls.single.sectionId, 'a');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // A 还没回来就换到 B。
    await tester.tap(find.text('板块 B'));
    await tester.pump();

    expect(source.calls, hasLength(2), reason: '换板块必须立刻发起新一轮请求');
    expect(source.calls.last.sectionId, 'b');

    // 迟到的 A 回来:结果丢弃,但不能把页面留在「加载中」。
    source.calls.first.gate.complete(_page('A'));
    await tester.pump();

    source.calls.last.gate.complete(_page('B'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '永久转圈就是这个 bug 的样子');
    expect(find.text('B1'), findsOneWidget);
    expect(find.text('A1'), findsNothing, reason: '旧代际的结果不该混进来');
  });

  testWidgets('迟到的旧请求出错也不污染新板块', (tester) async {
    final source = _GatedSource();
    await tester.pumpWidget(await _host(source));
    await tester.pump();

    await tester.tap(find.text('板块 B'));
    await tester.pump();

    source.calls.first.gate.completeError(StateError('源挂了'));
    await tester.pump();
    source.calls.last.gate.complete(_page('B'));
    await tester.pump();

    expect(find.text('B1'), findsOneWidget);
    expect(find.textContaining('源挂了'), findsNothing);
  });

  testWidgets('同一板块内滚动翻页仍照常推进', (tester) async {
    final source = _GatedSource();
    await tester.pumpWidget(await _host(source));
    await tester.pump();

    source.calls.single.gate.complete(
      Paged<Manga>([Manga(id: 'A1', title: 'A1')], hasNext: true),
    );
    await tester.pump();

    await tester.tap(find.text('板块 B'));
    await tester.pump();
    source.calls.last.gate.complete(_page('B'));
    await tester.pump();

    expect(source.calls.map((c) => c.sectionId).toList(), ['a', 'b']);
    expect(find.text('B1'), findsOneWidget);
  });
}
