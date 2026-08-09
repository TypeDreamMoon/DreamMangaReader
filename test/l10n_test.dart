import 'dart:convert';
import 'dart:io';

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

const _requiredNovelKeys = {
  'content_manga',
  'content_novel',
  'novel_browserNoSources',
  // 源选择条的「混合 · 全部源」/「选择源」已统一到 disc_* 那套(三档共用一副文案),
  // 小说不再有自己的 novel_browserAllSources / novel_browserSource。
  'novel_browserAllSourcesFailed',
  'novel_browserTranslatedQuery',
  'novel_browserPartialFailure',
  'novel_browserLoadFailed',
  'novel_browserNoResults',
  'novel_browserSourceCount',
  'novel_openInBrowser',
  'novel_addFavorite',
  'novel_removeFavorite',
  'novel_switchSource',
  'novel_directory',
  'novel_chaptersN',
  'novel_noChapters',
  'novel_downloadChapter',
  'novel_retryDownload',
  'novel_loadFailed',
  'novel_statusOngoing',
  'novel_statusCompleted',
  'novel_statusHiatus',
  'novel_statusCancelled',
  'novel_statusUnknown',
  'novel_switchSourceTitle',
  'novel_noSameTitleInSources',
  'novel_importLocal',
  'novel_onlyTxtEpub',
  'novel_parseFailed',
  'novel_importPreview',
  'novel_bookTitle',
  'novel_author',
  'novel_currentEncoding',
  'novel_operationFailed',
  'novel_confirmImport',
  'novel_unknownImportFormat',
  'novel_librarySearchHint',
  'novel_continueReading',
  'novel_libraryTitle',
  'novel_libraryEmpty',
  'novel_libraryNoMatch',
  'novel_sectionCount',
  'novel_fileMissing',
  'novel_readTo',
  'novel_localFormat',
  'novel_online',
  'novel_deleteLocal',
  'novel_deleteLocalTitle',
  'novel_deleteLocalConfirm',
  'novel_deleteMissingConfirm',
  'novel_deleteFailed',
  'novel_openFailed',
  'novel_sourceUnavailable',
  'novel_unnamed',
  'novel_historyEmpty',
  'novel_historyTooltip',
  'novel_downloadsEmpty',
  'novel_downloadsActive',
  'novel_downloadsHint',
  'novel_downloadsSummary',
  'novel_downloadsFailures',
  'novel_deleteOfflineTooltip',
  'novel_sourceUnavailableNoOffline',
  'novel_deleteOfflineTitle',
  'novel_deleteOfflineConfirm',
  'novel_offlineChapterDeleted',
  'novel_readerMissingRenderer',
  'novel_readerLoadFailed',
  'novel_readerBack',
  'novel_readerPreviousPage',
  'novel_readerNextPage',
  'novel_readerProgress',
  'novel_readerPaged',
  'novel_readerScroll',
  'novel_readerFont',
  'novel_readerSystemDefault',
  'novel_readerSerif',
  'novel_readerSansSerif',
  'novel_readerMonospace',
  'novel_readerTheme',
  'novel_readerThemeSepia',
  'novel_readerThemeWhite',
  'novel_readerThemeDark',
  'novel_readerThemeBlack',
  'novel_readerFontSize',
  'novel_readerLineHeight',
  'novel_readerParagraphSpacing',
  'novel_readerHorizontalMargin',
  'novel_readerKeepScreenOn',
  'novel_readerAutoHide',
  'novel_readerAutoHideOff',
  'novel_readerSeconds',
  'libraryUnifiedHistory',
  'libraryMangaFavorites',
  'libraryNovelFavorites',
  'libraryAnimeFavorites',
  'libraryHistoryEmpty',
  'libraryMangaFavoritesEmpty',
  'libraryNovelFavoritesEmpty',
  'libraryAnimeFavoritesEmpty',
  'animeFavorite',
  'animeUnfavorite',
  'animeHistoryProgress',
  'animeResumeFailed',
};

const _requiredBackgroundUpdateKeys = {
  'update_background',
  'update_backgroundHint',
  'update_retrying',
  'update_readyNotification',
  'update_notificationPermission',
  'update_expiredUrl',
};

void main() {
  test('four ARB files keep key parity and required feature copy', () {
    final files = [
      'lib/l10n/app_zh.arb',
      'lib/l10n/app_zh_Hant.arb',
      'lib/l10n/app_en.arb',
      'lib/l10n/app_ja.arb',
    ];
    final keysByFile = <String, Set<String>>{};
    for (final path in files) {
      final json = jsonDecode(File(path).readAsStringSync()) as Map;
      final keys = json.keys
          .whereType<String>()
          .where((key) => !key.startsWith('@'))
          .toSet();
      keysByFile[path] = keys;
      expect(keys, containsAll(_requiredNovelKeys), reason: path);
      expect(keys, containsAll(_requiredBackgroundUpdateKeys), reason: path);
      for (final key in _requiredNovelKeys) {
        expect((json[key] as String?)?.trim(), isNotEmpty,
            reason: '$path:$key');
      }
    }
    final template = keysByFile[files.first]!;
    for (final path in files.skip(1)) {
      expect(keysByFile[path], template, reason: path);
    }
  });

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

    await tester.pumpWidget(
        _app(const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')));
    await tester.pumpAndSettle();
    expect(find.text('書架'), findsOneWidget);
  });
}
