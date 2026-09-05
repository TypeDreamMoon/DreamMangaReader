// 发现页:内容类型的展示名必须走 l10n(枚举里塞中文会漏进英文/日文界面),
// 以及分页失败重试成功后错误态要跟着消失。
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/source_controller.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
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
}
