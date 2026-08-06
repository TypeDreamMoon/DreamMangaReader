import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/anime/anime_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('anime detail favorite action toggles its independent store',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final library = AnimeLibraryStore(persistDelay: Duration.zero);
    await library.load();
    addTearDown(library.dispose);

    await tester.pumpWidget(MaterialApp(
      home: AnimeLibraryScope(
        store: library,
        child: const Scaffold(
          body: AnimeFavoriteAction(
            meta: SourceMeta(
              id: 'anime-source',
              name: '测试源',
              script: '',
              kind: 'anime',
            ),
            anime: Manga(
              id: 'show',
              title: '完整番剧标题',
              cover: 'https://img.test/full.jpg',
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('anime-favorite')));
    await tester.pump();

    expect(library.isFavorite('anime-source', 'show'), isTrue);
    expect(library.favorites.single.title, '完整番剧标题');
    expect(library.favorites.single.cover, 'https://img.test/full.jpg');
    await library.flushPending();
  });
}
