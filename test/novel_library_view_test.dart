import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/features/library/history_page.dart';
import 'package:dream_manga_reader/features/novel/novel_library_view.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 解析一次再用:Windows 的 %TEMP% 往往是 8.3 短名(C:\Users\RUNNER~1\...),
    // 而被测的 _safeExistingFile 出于目录穿越防护会返回 resolveSymbolicLinks()
    // 之后的长名。不在这儿统一口径,断言就会拿短名去比长名 —— 只有用户名超过
    // 8 个字符的机器才会露出来(CI 的 runneradmin 是,开发机的短用户名不是)。
    sandbox = Directory(
      await (await Directory.systemTemp.createTemp('novel-library-ui-'))
          .resolveSymbolicLinks(),
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('local TXT loader slices normalized UTF-8 byte offsets', () async {
    final directory = Directory(
      '${sandbox.path}${Platform.pathSeparator}local-txt',
    );
    await directory.create();
    const content = '第一章\n甲乙\n第二章\n丙丁';
    final bytes = utf8.encode(content);
    final secondOffset = utf8.encode('第一章\n甲乙\n').length;
    await File('${directory.path}${Platform.pathSeparator}content.txt')
        .writeAsBytes(bytes);
    await File('${directory.path}${Platform.pathSeparator}index.json')
        .writeAsString(jsonEncode({
      'origin': 'localTxt',
      'title': '字节测试',
      'authors': ['作者'],
      'chapters': [
        {
          'id': 'c1',
          'title': '第一章',
          'contentOffset': 0,
          'endOffset': secondOffset,
        },
        {
          'id': 'c2',
          'title': '第二章',
          'contentOffset': secondOffset,
          'endOffset': bytes.length,
        },
      ],
    }));

    final book = await LocalNovelBook.open(directory);
    final document = await book.loadDocument(book.chapters.last);

    expect(document.format, NovelDocumentFormat.text);
    expect(document.content, '第二章\n丙丁');
  });

  test('local EPUB loader uses the chapter file as its file base URL',
      () async {
    final directory = Directory(
      '${sandbox.path}${Platform.pathSeparator}local-epub',
    );
    final resources = Directory(
      '${directory.path}${Platform.pathSeparator}resources${Platform.pathSeparator}OEBPS',
    );
    await resources.create(recursive: true);
    final chapterFile = File(
      '${resources.path}${Platform.pathSeparator}chapter.xhtml',
    );
    await chapterFile.writeAsString('<p><img src="images/a.png">正文</p>');
    await File('${directory.path}${Platform.pathSeparator}index.json')
        .writeAsString(jsonEncode({
      'origin': 'localEpub',
      'title': 'EPUB 测试',
      'authors': [],
      'chapters': [
        {
          'id': 'c1',
          'title': '第一章',
          'resource': 'OEBPS/chapter.xhtml',
        },
      ],
    }));

    final book = await LocalNovelBook.open(directory);
    final document = await book.loadDocument(book.chapters.single);

    expect(document.format, NovelDocumentFormat.html);
    expect(document.baseUrl, chapterFile.uri.toString());
    expect(document.content, contains('images/a.png'));
  });

  test('local deletion rejects directories outside the private novel root',
      () async {
    final support = Directory(
      '${sandbox.path}${Platform.pathSeparator}support',
    );
    final outside = Directory(
      '${sandbox.path}${Platform.pathSeparator}outside',
    );
    await support.create();
    await outside.create();

    await expectLater(
      deleteLocalNovelDirectory(
        outside.path,
        applicationSupportDirectory: () async => support,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outside.exists(), isTrue);
  });

  testWidgets('novel shelf shows a missing local copy explicitly',
      (tester) async {
    final store = NovelLibraryStore();
    await store.load();
    store.addLocal(NovelLibraryEntry.local(
      sha256: 'missing',
      title: '缺失的小说',
      privatePath: '${sandbox.path}${Platform.pathSeparator}does-not-exist',
      origin: NovelOrigin.localTxt,
    ));

    await tester.pumpWidget(MaterialApp(
      // 书架行走 palette(AppTokens 主题扩展),必须给真主题。
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: NovelLibraryScope(
        store: store,
        child: const Scaffold(body: NovelLibraryView()),
      ),
    ));

    expect(find.text('缺失的小说'), findsWidgets);
    expect(find.text('文件缺失'), findsOneWidget);
    store.dispose();
  });

  testWidgets('novel shelf search field follows the app bar toggle',
      (tester) async {
    final store = NovelLibraryStore();
    await store.load();
    store.addLocal(NovelLibraryEntry.local(
      sha256: 'toggle',
      title: '搜索用小说',
      privatePath: sandbox.path,
      origin: NovelOrigin.localTxt,
    ));

    Widget shelf({required bool searchVisible}) => MaterialApp(
          theme: buildTheme(AppThemeVariant.light),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: NovelLibraryScope(
            store: store,
            child: Scaffold(
              body: NovelLibraryView(searchVisible: searchVisible),
            ),
          ),
        );

    await tester.pumpWidget(shelf(searchVisible: false));
    expect(find.text('搜索小说书架'), findsNothing);

    await tester.pumpWidget(shelf(searchVisible: true));
    await tester.pumpAndSettle();
    expect(find.text('搜索小说书架'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '对不上的词');
    await tester.pumpAndSettle();
    expect(find.text('搜索用小说'), findsNothing);

    // 收起搜索框要退出筛选态,否则书架会「凭空少书」且没有可见的筛选提示。
    // findsWidgets:生成式封面也会把书名画上去,行标题之外还有一处。
    await tester.pumpWidget(shelf(searchVisible: false));
    await tester.pumpAndSettle();
    expect(find.text('搜索用小说'), findsWidgets);
    store.dispose();
  });

  testWidgets('a book listed twice gets distinct cover hero tags',
      (tester) async {
    // 同一本远端书会同时出现在「继续阅读」和书架列表里。两处封面都要飞入详情页,
    // 但 Hero tag 必须分开 —— 同屏出现两个相同 tag 时 Flutter 直接抛异常。
    final store = NovelLibraryStore();
    await store.load();
    store.toggleRemoteFavorite(NovelLibraryEntry.remote(
      sourceId: 'src',
      novelId: 'n1',
      title: '两处都在的小说',
    ));
    store.saveProgress(
      NovelIdentity.remote('src', 'n1').key,
      const NovelLocator(chapterId: 'c1', fraction: .3),
    );
    await store.flushPending();

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: NovelLibraryScope(
        store: store,
        child: const Scaffold(body: NovelLibraryView()),
      ),
    ));
    await tester.pumpAndSettle();

    final tags = tester
        .widgetList<Hero>(find.byType(Hero))
        .map((hero) => hero.tag)
        .toList();
    expect(tags, hasLength(2));
    expect(tags.toSet(), hasLength(2));
    expect(tester.takeException(), isNull);
    store.dispose();
  });

  testWidgets('local books get no hero tag', (tester) async {
    // 本地书点开的是阅读器而不是详情页,没有可飞过去的封面 —— 不该占 tag。
    final store = NovelLibraryStore();
    await store.load();
    store.addLocal(NovelLibraryEntry.local(
      sha256: 'local-only',
      title: '本地小说',
      privatePath: sandbox.path,
      origin: NovelOrigin.localTxt,
    ));

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: NovelLibraryScope(
        store: store,
        child: const Scaffold(body: NovelLibraryView()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Hero), findsNothing);
    store.dispose();
  });

  testWidgets('novel history appears in the unified history list',
      (tester) async {
    final mangaStore = LibraryStore();
    final novelStore = NovelLibraryStore();
    final animeStore = AnimeLibraryStore();
    await novelStore.load();
    await animeStore.load();
    novelStore.addLocal(NovelLibraryEntry.local(
      sha256: 'history',
      title: '小说历史甲',
      privatePath: sandbox.path,
      origin: NovelOrigin.localTxt,
    ));
    novelStore.saveProgress(
      'local:history',
      const NovelLocator(chapterId: 'c8', fraction: .5),
    );

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: mangaStore,
        child: NovelLibraryScope(
          store: novelStore,
          child: AnimeLibraryScope(
            store: animeStore,
            child: const HistoryPage(),
          ),
        ),
      ),
    ));

    expect(find.text('小说历史甲'), findsWidgets);
    expect(find.byType(SegmentedButton), findsNothing);
    mangaStore.dispose();
    novelStore.dispose();
    animeStore.dispose();
  });
}
