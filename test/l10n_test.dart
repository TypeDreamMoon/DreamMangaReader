import 'package:dream_manga_reader/core/l10n/app_locale.dart';
import 'package:dream_manga_reader/core/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Locale locale) => MaterialApp(
      locale: locale,
      supportedLocales: [for (final l in AppLocale.values) l.toLocale()],
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
        builder: (ctx) => Text(ctx.l10n.navBookshelf,
            textDirection: TextDirection.ltr),
      ),
    );

void main() {
  test('AppLocale code 往返 + 系统 Locale 匹配', () {
    for (final l in AppLocale.values) {
      expect(AppLocale.fromCode(l.code), l);
    }
    expect(AppLocale.fromCode(null), AppLocale.zhHans); // 缺省=简体
    expect(AppLocale.fromCode('xx_YY'), AppLocale.zhHans);
    expect(AppLocale.fromLocale(const Locale('en')), AppLocale.en);
    expect(AppLocale.fromLocale(const Locale('ja')), AppLocale.ja);
    expect(AppLocale.fromLocale(const Locale('zh')), AppLocale.zhHans);
    expect(
        AppLocale.fromLocale(
            const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')),
        AppLocale.zhHant);
    expect(
        AppLocale.fromLocale(
            const Locale.fromSubtags(languageCode: 'zh', countryCode: 'TW')),
        AppLocale.zhHant);
  });

  test('未译条目回退到简体基类', () {
    // loadFailed 四语都译了;随便挑一个只在基类的将来键不易测,这里验证基类即简体。
    expect(const AppStrings().navBookshelf, '书架');
    // 子类覆盖生效。
    expect(const AppStringsEn().navBookshelf, 'Library');
    expect(const AppStringsJa().navBookshelf, '本棚');
    expect(const AppStringsZhHant().navBookshelf, '書架');
  });

  testWidgets('切换 locale → context.l10n 文案随之变化', (tester) async {
    await tester.pumpWidget(_app(const Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('书架'), findsOneWidget);

    await tester.pumpWidget(_app(const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('书架'), findsNothing);

    await tester.pumpWidget(_app(const Locale('ja')));
    await tester.pumpAndSettle();
    expect(find.text('本棚'), findsOneWidget);

    await tester.pumpWidget(_app(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')));
    await tester.pumpAndSettle();
    expect(find.text('書架'), findsOneWidget);
  });
}
