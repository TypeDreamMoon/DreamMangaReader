import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/features/novel/novel_cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _onePixelPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  testWidgets('renders an inline novel cover from memory', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(AppThemeVariant.light),
        home: const Scaffold(
          body: SizedBox(
            width: 120,
            child: NovelCover(
              novel: Novel(
                id: 'inline-novel-cover',
                title: '内嵌小说封面',
                cover: _onePixelPng,
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
  });
}
