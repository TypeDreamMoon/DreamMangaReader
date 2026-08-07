import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_settings_sheet.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings expose five modes and complete advanced controls',
      (tester) async {
    await tester.pumpWidget(_harness(onChanged: (_) {}));

    for (final mode in NovelPageTurnMode.values) {
      expect(find.byKey(Key('novel-turn-mode-${mode.name}')), findsOneWidget);
    }
    for (final key in const [
      'novel-setting-brightness',
      'novel-setting-line-height',
      'novel-setting-paragraph-spacing',
      'novel-setting-horizontal-margin',
      'novel-setting-top-margin',
      'novel-setting-bottom-margin',
      'novel-setting-first-line-indent',
      'novel-setting-alignment',
      'novel-setting-single-hand',
      'novel-setting-status-chapter',
      'novel-setting-status-page',
      'novel-setting-status-progress',
      'novel-setting-status-time',
      'novel-setting-status-battery',
      'novel-setting-reset',
    ]) {
      await _scrollToBuilt(tester, Key(key));
      expect(find.byKey(Key(key)), findsOneWidget);
    }
  });

  testWidgets('mode selection and reset emit complete preferences',
      (tester) async {
    final changes = <NovelReaderPreferences>[];
    await tester.pumpWidget(
      _harness(
        value: const NovelReaderPreferences(
          turnMode: NovelPageTurnMode.translate,
          fontSize: 25,
          topMargin: 40,
          showBattery: false,
        ),
        onChanged: changes.add,
      ),
    );

    await tester.tap(find.byKey(const Key('novel-turn-mode-cover')));
    await tester.pump();
    expect(changes.last.turnMode, NovelPageTurnMode.cover);

    await _scrollToBuilt(tester, const Key('novel-setting-reset'));
    await tester.drag(find.byType(ListView), const Offset(0, -80));
    await tester.pump();
    await tester.tap(find.byKey(const Key('novel-setting-reset')));
    await tester.pump();

    expect(changes.last.turnMode, NovelPageTurnMode.curl);
    expect(changes.last.fontSize, 18);
    expect(changes.last.topMargin, 16);
    expect(changes.last.showBattery, isTrue);
  });
}

Future<void> _scrollToBuilt(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  for (var attempt = 0; attempt < 20 && finder.evaluate().isEmpty; attempt++) {
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pump();
  }
  if (finder.evaluate().isNotEmpty) {
    await tester.ensureVisible(finder);
    await tester.pump();
  }
}

Widget _harness({
  NovelReaderPreferences value = const NovelReaderPreferences(),
  required ValueChanged<NovelReaderPreferences> onChanged,
}) {
  return MaterialApp(
    theme: buildTheme(AppThemeVariant.light),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      body: NovelReaderSettingsSheet(value: value, onChanged: onChanged),
    ),
  );
}
