import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/library/manga_cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _onePixelPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  testWidgets('renders an inline catalog cover from memory', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();

    await tester.pumpWidget(
      LibraryScope(
        store: store,
        child: MaterialApp(
          theme: buildTheme(AppThemeVariant.light),
          home: const Scaffold(
            body: SizedBox(
              width: 120,
              child: MangaCover(
                manga: Manga(
                  id: 'inline-cover',
                  title: '内嵌封面',
                  cover: _onePixelPng,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final providers = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .toList();
    expect(providers.whereType<MemoryImage>(), isNotEmpty);
    expect(tester.takeException(), isNull);

    store.dispose();
  });
}
