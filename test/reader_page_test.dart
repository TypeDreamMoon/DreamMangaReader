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
