import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/ui/app_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('app background keeps backdrop separate from foreground',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final store = LibraryStore();
    await store.load();
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.dark),
      home: LibraryScope(
        store: store,
        child: const AppBackground(
          child: Scaffold(body: Text('foreground')),
        ),
      ),
    ));

    expect(find.byType(AppBackdrop), findsOneWidget);
    expect(find.text('foreground'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBackdrop),
        matching: find.byType(ColoredBox),
      ),
      findsWidgets,
    );
  });
}
