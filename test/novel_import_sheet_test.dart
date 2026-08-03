import 'dart:io';

import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/import/epub_novel_importer.dart';
import 'package:dream_manga_reader/core/novel/import/txt_chapter_parser.dart';
import 'package:dream_manga_reader/core/novel/import/txt_novel_importer.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/features/novel/novel_import_sheet.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory sandbox;
  late File selectedFile;
  late Directory installedDirectory;
  late NovelLibraryStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('novel-import-ui-');
    selectedFile = File(
      '${sandbox.path}${Platform.pathSeparator}sample.txt',
    );
    await selectedFile.writeAsString('第一章 开始\n正文');
    installedDirectory = Directory(
      '${sandbox.path}${Platform.pathSeparator}installed',
    );
    await installedDirectory.create();
    store = NovelLibraryStore();
    await store.load();
  });

  tearDown(() async {
    store.dispose();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  testWidgets('TXT preview retries Big5 before any library write',
      (tester) async {
    final forcedEncodings = <String?>[];
    var imports = 0;
    final services = NovelImportServices(
      pickFile: () async => selectedFile,
      previewTxt: (file, {forcedEncoding}) async {
        forcedEncodings.add(forcedEncoding);
        return _txtPreview(encoding: forcedEncoding ?? 'gb18030');
      },
      importTxt: (preview) async {
        imports++;
        return installedDirectory;
      },
      previewEpub: (_) => throw StateError('not EPUB'),
      importEpub: (_) => throw StateError('not EPUB'),
    );

    await tester.pumpWidget(_harness(store, services));
    await tester.tap(find.text('导入本地小说'));
    await tester.pumpAndSettle();

    expect(find.text('GB18030 / GBK'), findsOneWidget);
    expect(find.text('2 章'), findsOneWidget);
    expect(store.entries, isEmpty);
    expect(imports, 0);

    await tester.tap(find.text('Big5'));
    await tester.pumpAndSettle();

    expect(forcedEncodings.last, 'big5');
    expect(store.entries, isEmpty);
    expect(imports, 0);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.entries, isEmpty);
  });

  testWidgets('confirmed EPUB import uses edited metadata', (tester) async {
    selectedFile = File(
      '${sandbox.path}${Platform.pathSeparator}sample.epub',
    );
    final preview = EpubNovelImportPreview(
      sha256: 'ABC123',
      title: '原书名',
      authors: const ['原作者'],
      chapters: const [NovelChapter(id: 'c1', title: '第一章')],
      hasCover: false,
      language: 'zh',
      originalBytes: const [1, 2, 3],
      resources: const {},
      chapterResources: const {},
    );
    final services = NovelImportServices(
      pickFile: () async => selectedFile,
      previewTxt: (_, {forcedEncoding}) => throw StateError('not TXT'),
      importTxt: (_) => throw StateError('not TXT'),
      previewEpub: (_) async => preview,
      importEpub: (_) async => ImportedEpubNovel(
        directory: installedDirectory,
        preview: preview,
      ),
    );

    await tester.pumpWidget(_harness(store, services));
    await tester.tap(find.text('导入本地小说'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('novel-import-title')),
      '修改后的书名',
    );
    await tester.enterText(
      find.byKey(const Key('novel-import-author')),
      '修改后的作者',
    );
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();

    final entry = store.entryFor('local:abc123');
    expect(entry?.title, '修改后的书名');
    expect(entry?.authors, ['修改后的作者']);
    expect(entry?.origin, NovelOrigin.localEpub);
    expect(entry?.privatePath, installedDirectory.path);
  });
}

Widget _harness(NovelLibraryStore store, NovelImportServices services) {
  return MaterialApp(
    // 小说界面走 palette(AppTokens 主题扩展),裸 MaterialApp 取不到。
    theme: buildTheme(AppThemeVariant.light),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: NovelLibraryScope(
      store: store,
      child: Scaffold(
        body: Center(child: NovelImportButton(services: services)),
      ),
    ),
  );
}

TxtNovelImportPreview _txtPreview({required String encoding}) {
  const text = '第一章 开始\n正文一\n第二章 继续\n正文二';
  final parsed = TxtChapterParser.parse(text);
  return TxtNovelImportPreview(
    sha256: 'ABC123',
    title: '测试小说',
    authors: const ['作者甲'],
    chapters: parsed.chapters
        .map((chapter) => NovelChapter(id: chapter.id, title: chapter.title))
        .toList(growable: false),
    encoding: encoding,
    normalizedText: parsed.normalizedText,
    parsed: parsed,
  );
}
