import 'package:dream_manga_reader/core/l10n/app_locale.dart';
import 'package:dream_manga_reader/core/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 用 gen-l10n 生成的 AppLocalizations 渲染,验证:委托解析 + 切 locale → 文案随之变化
// + 未译条目回退到简体模板。
Widget _app(Locale locale) => MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(
        builder: (ctx) =>
            Text(ctx.l10n.navBookshelf, textDirection: TextDirection.ltr),
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

  test('AppLocale.toLocale 与生成的 supportedLocales 一一对应', () {
    final supported = AppLocalizations.supportedLocales.toSet();
    for (final l in AppLocale.values) {
      expect(supported.contains(l.toLocale()), isTrue,
          reason: '${l.code} 的 Locale 应在生成的 supportedLocales 里');
    }
    expect(supported.length, AppLocale.values.length);
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
