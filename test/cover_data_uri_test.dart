import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/library/manga_cover.dart';
import 'package:dream_manga_reader/features/novel/novel_cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cover =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

  testWidgets('private source cover renders a Base64 data image',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NovelCover(
            novel: Novel(id: 'private-book', title: '私有作品', cover: cover),
          ),
        ),
      ),
    );

    final images = tester.widgetList<Image>(find.byType(Image));
    expect(images.map((image) => image.image), contains(isA<MemoryImage>()));
  });

  testWidgets('manga cards render a private Base64 cover', (tester) async {
    final store = LibraryStore();
    addTearDown(store.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: const [AppTokens(palette: AppPalette.oled)],
        ),
        home: LibraryScope(
          store: store,
          child: const Scaffold(
            body: SizedBox(
              width: 120,
              child: MangaCover(
                manga: Manga(id: 'private-manga', title: '私有漫画', cover: cover),
              ),
            ),
          ),
        ),
      ),
    );

    final images = tester.widgetList<Image>(find.byType(Image));
    expect(images.map((image) => image.image), contains(isA<MemoryImage>()));
  });
}
