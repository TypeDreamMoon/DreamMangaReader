import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/source/author_match.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/detail/author_works_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _meta = SourceMeta(id: 'src', name: '测试源', script: '', kind: 'manga');

class _FakeSource implements MangaSource {
  _FakeSource(this.results, this.queries);

  final List<Manga> results;
  final List<String> queries;

  @override
  Future<Paged<Manga>> getSearch(String query, int page,
      {Map<String, Object?>? filters}) async {
    queries.add(query);
    return Paged(results);
  }

  @override
  void dispose() {}

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<LibraryStore> _library() async {
  SharedPreferences.setMockInitialValues(const {});
  final store = LibraryStore();
  await store.load();
  return store;
}

void main() {
  group('AuthorMatch', () {
    test('splits multi-author fields on every common separator', () {
      expect(AuthorMatch.split('尾田荣一郎 / 集英社'), ['尾田荣一郎', '集英社']);
      expect(AuthorMatch.split('A，B、C;D'), ['A', 'B', 'C', 'D']);
      expect(AuthorMatch.split('  '), isEmpty);
    });

    test('ignores role suffixes, punctuation and case', () {
      expect(AuthorMatch.matches(const ['尾田荣一郎 著'], '尾田荣一郎'), isTrue);
      expect(AuthorMatch.matches(const ['CLAMP'], 'clamp'), isTrue);
      expect(AuthorMatch.matches(const ['富坚·义博'], '富坚义博'), isTrue);
      expect(AuthorMatch.matches(const ['青山刚昌'], '尾田荣一郎'), isFalse);
      expect(AuthorMatch.matches(const [], '尾田荣一郎'), isFalse);
      expect(AuthorMatch.matches(const ['尾田荣一郎'], ''), isFalse);
    });

    test('accepts a containing form so parenthesised aliases still hit', () {
      expect(AuthorMatch.matches(const ['CLAMP(大川七濑)'], 'CLAMP'), isTrue);
    });
  });

  testWidgets('author page searches by author and flags confirmed matches',
      (tester) async {
    final store = await _library();
    addTearDown(store.dispose);
    final queries = <String>[];
    final opened = <String>[];
    final source = _FakeSource(
      const [
        Manga(id: 'a', title: '同作者新作', authors: ['尾田荣一郎 著']),
        Manga(id: 'b', title: '只是关键词命中', authors: ['别人']),
        Manga(id: 'self', title: '当前这本', authors: ['尾田荣一郎']),
      ],
      queries,
    );

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: store,
        child: AuthorWorksPage(
          author: '尾田荣一郎',
          meta: _meta,
          kind: 'manga',
          excludeMangaId: 'self',
          sourceBuilder: (_) => source,
          onOpen: (_, __, manga, ___) => opened.add(manga.id),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 用作者名去搜,而不是书名。
    expect(queries, ['尾田荣一郎']);
    // 当前这本不重复出现;作者字段真的对上的排在前面。
    expect(find.text('当前这本'), findsNothing);
    expect(find.text('同作者新作'), findsOneWidget);
    expect(find.text('只是关键词命中'), findsOneWidget);
    final confirmed = tester.getTopLeft(find.text('同作者新作'));
    final loose = tester.getTopLeft(find.text('只是关键词命中'));
    expect(confirmed.dy <= loose.dy, isTrue);

    await tester.tap(find.text('同作者新作'));
    await tester.pump();
    expect(opened, ['a']);
  });

  testWidgets('author page reports when the author has no other works',
      (tester) async {
    final store = await _library();
    addTearDown(store.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: store,
        child: AuthorWorksPage(
          author: '无名氏',
          meta: _meta,
          kind: 'manga',
          sourceBuilder: (_) => _FakeSource(const [], []),
          onOpen: (_, __, ___, ____) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('author-works-empty')), findsOneWidget);
  });
}
