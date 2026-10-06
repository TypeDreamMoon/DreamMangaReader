import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/bangumi/bangumi_api.dart';
import 'package:dream_manga_reader/features/common/bangumi_card.dart';
import 'package:dream_manga_reader/features/detail/bangumi_search_sheet.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bangumi 卡片与手动搜索弹层曾把文案写死成简体中文,英文用户照样看到中文。
/// 这几条钉住「跟着 locale 走」。
void main() {
  testWidgets('bangumi card localises its matching state', (tester) async {
    await tester.pumpWidget(_app(
      const BangumiCard(loading: true, info: null),
    ));
    expect(find.text('Matching Bangumi…'), findsOneWidget);
  });

  testWidgets('bangumi card localises the unmatched state', (tester) async {
    await tester.pumpWidget(_app(
      BangumiCard(loading: false, info: null, onRematch: () {}),
    ));
    expect(find.text('No matching Bangumi entry'), findsOneWidget);
    expect(find.text('Search manually'), findsOneWidget);
  });

  testWidgets('bangumi card localises episode count and actions',
      (tester) async {
    await tester.pumpWidget(_app(
      BangumiCard(loading: false, info: _info(), onRematch: () {}),
    ));
    expect(find.text('12 ch.'), findsOneWidget);
    expect(find.byTooltip('Rematch'), findsOneWidget);
    expect(find.byTooltip('Open in Bangumi'), findsOneWidget);
  });

  testWidgets('bangumi search sheet localises its hint', (tester) async {
    await tester.pumpWidget(_app(
      const SizedBox(
        height: 400,
        child: BangumiSearchSheet(initialQuery: ''),
      ),
    ));
    expect(find.text('Enter a title'), findsOneWidget);
  });
}

BangumiInfo _info() => const BangumiInfo(
      id: 1,
      name: '测试条目',
      nameOrig: '',
      score: 8.4,
      rank: 42,
      votes: 1200,
      tags: [],
      summary: '',
      date: '',
      eps: 12,
      volumes: 0,
      image: '',
      infobox: [],
    );

Widget _app(Widget home) => MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: home),
    );
