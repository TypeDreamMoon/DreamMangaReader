import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/features/library/history_page.dart';
import 'package:dream_manga_reader/features/library/library_page.dart';
import 'package:dream_manga_reader/features/novel/novel_library_view.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('novel-library-ui-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  testWidgets('library kind switch never renders manga and novel together',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _SwitchHarness()));

    expect(find.text('漫画甲'), findsOneWidget);
    expect(find.text('小说乙'), findsNothing);
    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle();
    expect(find.text('小说乙'), findsOneWidget);
    expect(find.text('漫画甲'), findsNothing);
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
      privatePath:
          '${sandbox.path}${Platform.pathSeparator}does-not-exist',
      origin: NovelOrigin.localTxt,
    ));

    await tester.pumpWidget(MaterialApp(
      home: NovelLibraryScope(
        store: store,
        child: const Scaffold(body: NovelLibraryView()),
      ),
    ));

    expect(find.text('缺失的小说'), findsWidgets);
    expect(find.text('文件缺失'), findsOneWidget);
    store.dispose();
  });

  testWidgets('novel history is isolated from manga history', (tester) async {
    final mangaStore = LibraryStore();
    final novelStore = NovelLibraryStore();
    await novelStore.load();
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
          child: const HistoryPage(showNovelInitially: true),
        ),
      ),
    ));

    expect(find.text('小说历史甲'), findsWidgets);
    await tester.tap(find.text('漫画'));
    await tester.pump();
    expect(find.text('小说历史甲'), findsNothing);
    mangaStore.dispose();
    novelStore.dispose();
  });
}

class _SwitchHarness extends StatefulWidget {
  const _SwitchHarness();

  @override
  State<_SwitchHarness> createState() => _SwitchHarnessState();
}

class _SwitchHarnessState extends State<_SwitchHarness> {
  var _kind = LibraryKind.manga;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: LibraryKindSwitch(
          selected: _kind,
          onSelected: (value) => setState(() => _kind = value),
        ),
      ),
      body: _kind == LibraryKind.manga
          ? const Text('漫画甲')
          : const Text('小说乙'),
    );
  }
}
