import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/features/reader/reader_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';

const _onePixelPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

List<PageImage> _pages(int n) =>
    [for (var i = 0; i < n; i++) PageImage(index: i, url: _onePixelPng)];

void main() {
  Widget harness({
    required LibraryStore store,
    required MangaSource source,
    required List<Chapter> chapters,
    int index = 0,
    int initialPage = 0,
    void Function(int loadedChapters, int flatPages)? onDebugFlat,
  }) =>
      LibraryScope(
        store: store,
        child: MaterialApp(
          theme: buildTheme(AppThemeVariant.light),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: ReaderPage(
            source: source,
            manga: const Manga(id: 'm', title: '测试'),
            chapters: chapters,
            index: index,
            initialPage: initialPage,
            onDebugFlat: onDebugFlat,
          ),
        ),
      );

  /// 回归 E1:双页模式下 `initialPage` 是**扁平页号**,PageView 的槽位却是
  /// `flat ~/ 2`。旧代码把扁平页号直接塞给 `PageController(initialPage:)`,
  /// 续读第 21 页会落到第 41/42 页去。
  testWidgets('double-page resume lands on the slot holding the saved page',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();
    store.doublePage = true;

    await tester.pumpWidget(harness(
      store: store,
      source: _FakeSource({'c1': _pages(40)}),
      chapters: const [Chapter(id: 'c1', name: '第1话')],
      initialPage: 20,
    ));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller.page, 10,
        reason: '扁平第 20 页在双页模式下是第 10 个槽位;'
            '旧代码塞扁平页号 20,会落到第 41/42 页(越界后夹到最后一个槽位)');

    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('single-page resume still uses the flat page directly',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();
    store.doublePage = false;

    await tester.pumpWidget(harness(
      store: store,
      source: _FakeSource({'c1': _pages(40)}),
      chapters: const [Chapter(id: 'c1', name: '第1话')],
      initialPage: 20,
    ));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller.page, 20);

    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  /// 续读页号超出本章页数时会被 clamp;控制器必须跟着对齐,否则 PageView 停在
  /// 一个不存在的槽位上。
  testWidgets('an out-of-range resume page is clamped on the controller too',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();
    store.doublePage = false;

    await tester.pumpWidget(harness(
      store: store,
      source: _FakeSource({'c1': _pages(5)}),
      chapters: const [Chapter(id: 'c1', name: '第1话')],
      initialPage: 99,
    ));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(controller.page, 4);

    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  /// 回归 E11:双页模式下一次跨两页,3 页的余量意味着「最后一对开页」翻到时
  /// 下一章才刚开始拉;阈值要放宽到 4。
  testWidgets('double page starts the next chapter one spread earlier',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();
    store.doublePage = true;

    var loadedChapters = 0;
    await tester.pumpWidget(harness(
      store: store,
      source: _FakeSource({'c1': _pages(10), 'c2': _pages(10)}),
      chapters: const [
        Chapter(id: 'c1', name: '第1话'),
        Chapter(id: 'c2', name: '第2话'),
      ],
      // 扁平第 6 页:10-4 == 6,双页阈值下正好该开始接续(单页阈值 3 则不会)。
      initialPage: 6,
      onDebugFlat: (chapters, _) => loadedChapters = chapters,
    ));
    await tester.pumpAndSettle();

    expect(loadedChapters, 2, reason: '双页阈值 4:扁平第 6 页起就该接上下一章');

    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('single page keeps the 3-page threshold', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();
    store.doublePage = false;

    var loadedChapters = 0;
    await tester.pumpWidget(harness(
      store: store,
      source: _FakeSource({'c1': _pages(10), 'c2': _pages(10)}),
      chapters: const [
        Chapter(id: 'c1', name: '第1话'),
        Chapter(id: 'c2', name: '第2话'),
      ],
      initialPage: 6,
      onDebugFlat: (chapters, _) => loadedChapters = chapters,
    ));
    await tester.pumpAndSettle();

    expect(loadedChapters, 1, reason: '单页阈值仍是 3,第 6 页还不接续');

    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  /// 回归 E7:连读接不上下一章原本被 `catch (_) {}` 吞掉 —— 用户只看到内容
  /// 莫名断掉,而每次滑动都会重打同一个失败请求。
  testWidgets('a failed next-chapter load shows a retry instead of silently '
      'refetching on every page turn', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();

    final source = _FakeSource(
      {'c1': _pages(3), 'c2': _pages(3)},
      failing: {'c2'},
    );
    var loadedChapters = 0;
    await tester.pumpWidget(harness(
      store: store,
      source: source,
      chapters: const [
        Chapter(id: 'c1', name: '第1话'),
        Chapter(id: 'c2', name: '第2话'),
      ],
      onDebugFlat: (chapters, _) => loadedChapters = chapters,
    ));
    await tester.pumpAndSettle();

    expect(source.calls['c2'], 1, reason: '首次接续尝试过一次');
    expect(find.text('加载下一章失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 再翻几页:失败态已记住,不该再打请求。
    await tester.tap(find.byType(PageView), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(source.calls['c2'], 1, reason: '失败后不再每次翻页重打');

    // 点重试 → 源恢复正常,下一章接上,提示消失。
    source.failing.remove('c2');
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(source.calls['c2'], 2);
    expect(loadedChapters, 2);
    expect(find.text('加载下一章失败'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });
}

class _FakeSource implements MangaSource {
  _FakeSource(this.pagesByChapter, {Set<String>? failing})
      : failing = {...?failing};

  final Map<String, List<PageImage>> pagesByChapter;
  final Set<String> failing;
  final Map<String, int> calls = {};

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
  void dispose() {}

  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) async {
    calls[chapterId] = (calls[chapterId] ?? 0) + 1;
    if (failing.contains(chapterId)) {
      throw StateError('boom: $chapterId');
    }
    return pagesByChapter[chapterId] ?? const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
