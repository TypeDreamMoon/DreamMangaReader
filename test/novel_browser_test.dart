import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/source_controller.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/novel_source.dart';
import 'package:dream_manga_reader/core/source/chinese_fold.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/novel/novel_browser.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SearchSource implements NovelSource {
  _SearchSource(this.meta, this.result, {this.error});

  final SourceMeta meta;
  final List<Novel> result;
  final Object? error;

  @override
  String get id => meta.id;

  @override
  String get name => meta.name;

  @override
  List<FilterDef> get filters => const [];

  @override
  List<SourceSection> get sections => const [];

  @override
  void dispose() {}

  @override
  Future<Paged<NovelChapter>> getNovelChapters(String novelId, {int? page}) {
    throw UnimplementedError();
  }

  @override
  Future<Paged<Novel>> getNovelDiscovery(int page,
          {Map<String, Object?>? filters}) async =>
      Paged(result);

  @override
  Future<Novel> getNovelDetail(String novelId) {
    throw UnimplementedError();
  }

  @override
  Future<NovelDocument> getNovelDocument(String novelId, String chapterId) {
    throw UnimplementedError();
  }

  @override
  Future<Paged<Novel>> getNovelSearch(String query, int page,
      {Map<String, Object?>? filters}) async {
    if (error != null) throw error!;
    if (meta.id == 'b') {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return Paged(result);
  }

  @override
  Future<Paged<Novel>> getNovelSection(String sectionId, int page) {
    throw UnimplementedError();
  }
}

void main() {
  testWidgets('mixed novel search isolates failures and deduplicates titles',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await ChineseFold.load();
    const sources = [
      SourceMeta(id: 'a', name: '来源 A', script: '', kind: 'novel'),
      SourceMeta(id: 'b', name: '来源 B', script: '', kind: 'novel'),
      SourceMeta(id: 'broken', name: '故障源', script: '', kind: 'novel'),
    ];
    registeredSources = [...sources];
    final library = LibraryStore();
    await library.load();
    final controller = SourceController(sources.first);
    await controller.load();
    final key = GlobalKey<NovelBrowserState>();

    NovelSource build(SourceMeta meta) => switch (meta.id) {
          'a' => _SearchSource(
              meta,
              const [Novel(id: 'a1', title: '诡秘之主')],
            ),
          'b' => _SearchSource(
              meta,
              const [Novel(id: 'b1', title: '詭秘之主')],
            ),
          _ => _SearchSource(meta, const [], error: Exception('timeout')),
        };

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: library,
        child: SourceScope(
          controller: controller,
          child: Scaffold(
            body: Column(
              children: [
                TextField(
                  onSubmitted: (query) => key.currentState?.runSearch(query),
                ),
                Expanded(
                  child: NovelBrowser(
                    key: key,
                    sourceBuilder: build,
                    sourceCatalog: sources,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '诡秘');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('诡秘之主'), findsOneWidget);
    expect(find.text('2 个来源'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    library.dispose();
    controller.dispose();
    registeredSources = [];
  });
}
