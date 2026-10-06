import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/l10n/app_strings.dart';
import 'package:dream_manga_reader/features/shell/splash_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpSplash(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    theme: buildTheme(AppThemeVariant.dark),
    home: const SplashGate(child: SizedBox.shrink()),
  ));
  await tester.pump();
}

void main() {
  testWidgets('启动页那句说明跟着语言走,品牌名不动', (tester) async {
    await _pumpSplash(tester, const Locale('zh'));
    expect(find.text('梦漫 · 漫画阅读器'), findsOneWidget);

    await _pumpSplash(tester, const Locale('en'));
    expect(find.text('梦漫 · Manga Reader'), findsOneWidget);
    // 英文界面上不该再冒出写死的中文。
    expect(find.text('梦漫 · 漫画阅读器'), findsNothing);

    await _pumpSplash(tester, const Locale('ja'));
    expect(find.text('梦漫 · マンガリーダー'), findsOneWidget);

    await _pumpSplash(
        tester, const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));
    expect(find.text('梦漫 · 漫畫閱讀器'), findsOneWidget);

    await tester.pumpAndSettle();
  });
}
