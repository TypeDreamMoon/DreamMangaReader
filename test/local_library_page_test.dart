import 'dart:io';

import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/local_media_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:dream_manga_reader/features/local/local_library_detail_page.dart';
import 'package:dream_manga_reader/features/local/local_library_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('empty state offers both ways to add media', (tester) async {
    final fixture = await _Fixture.create(tester);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(const LocalLibraryPage()));
    await tester.pumpAndSettle();

    expect(find.text('还没有本地媒体'), findsOneWidget);
    expect(find.text('添加文件夹'), findsOneWidget);
    expect(find.text('添加文件'), findsOneWidget);
  });

  testWidgets('library cards show name and item count', (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 3);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(const LocalLibraryPage()));
    await tester.pumpAndSettle();

    expect(find.text('本地库'), findsOneWidget);
    expect(find.text('测试剧集'), findsOneWidget);
    expect(find.text('3 个条目'), findsWidgets);
  });

  testWidgets('tapping a library opens its detail page', (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 2);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(const LocalLibraryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试剧集'));
    await tester.pumpAndSettle();

    expect(find.byType(LocalLibraryDetailPage), findsOneWidget);
    expect(find.text('剧集'), findsOneWidget);
    expect(find.text('E01'), findsOneWidget);
    expect(find.text('E02'), findsOneWidget);
  });

  testWidgets('renaming a library only changes the card title', (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 1);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(const LocalLibraryPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    // 空名字保存按钮不可用(库名是卡片上唯一的标识)。
    await tester.enterText(find.byKey(const Key('local-rename-field')), '   ');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );

    await tester.enterText(
        find.byKey(const Key('local-rename-field')), 'Loki S02');
    await tester.pump();
    await tester.tap(find.text('保存'));
    // store 走真落盘:先 pump 让异步链跑起来,再 runAsync 让 I/O 完成。
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(fixture.store.library(fixture.libraryId)!.name, 'Loki S02');
    expect(find.text('Loki S02'), findsOneWidget);
    expect(find.text('测试剧集'), findsNothing);
    // 名字只是展示:条目一个不少。
    expect(fixture.store.items(fixture.libraryId).length, 1);
  });

  testWidgets('removing a library only drops the index', (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 1);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(const LocalLibraryPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除库'));
    await tester.pumpAndSettle();
    // 二次确认(对话框里的按钮也叫「移除库」)。
    await tester.tap(find.text('移除库').last);
    // 确认后 store 走真落盘:先 pump 让异步链跑起来,再 runAsync 让 I/O 完成,
    // 最后 pump 刷 UI(_busy 期间是无限动画,不能用 pumpAndSettle)。
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(fixture.store.libraries, isEmpty);
    expect(find.text('还没有本地媒体'), findsOneWidget);
    expect(fixture.videoFiles.first.existsSync(), isTrue);
  });
}

class _Fixture {
  _Fixture({
    required this.root,
    required this.store,
    required this.anime,
    required this.videoFiles,
  });

  final Directory root;
  final LocalMediaStore store;
  final AnimeLibraryStore anime;
  final List<File> videoFiles;
  String libraryId = '';

  static Future<_Fixture> create(WidgetTester tester, {int itemCount = 0}) async {
    SharedPreferences.setMockInitialValues(const {});
    // 必须用 sync 版:假异步区里 `await createTemp()` 这种真 I/O 永远不完成。
    final root = Directory.systemTemp.createTempSync('local_library_page');
    final store = LocalMediaStore(rootProvider: () async => root.path);
    final anime = AnimeLibraryStore(persistDelay: Duration.zero);
    final folder = Directory('${root.path}${Platform.pathSeparator}Show')
      ..createSync(recursive: true);
    final videos = <File>[];
    for (var i = 1; i <= itemCount; i++) {
      final file = File(
          '${folder.path}${Platform.pathSeparator}Show.E${i.toString().padLeft(2, '0')}.mkv')
        ..writeAsBytesSync(List<int>.filled(1024 * i, 3));
      videos.add(file);
    }
    final fixture = _Fixture(
      root: root,
      store: store,
      anime: anime,
      videoFiles: videos,
    );
    // 落盘是真 I/O:widget 测试的假异步区里它永远不完成(B 的提醒),必须 runAsync。
    final built = await tester.runAsync(() async {
      await anime.load();
      await store.load();
      if (itemCount > 0) {
        final library = await store.addLibrary(
          name: '测试剧集',
          kind: LocalLibraryKind.folder,
          path: folder.path,
          items: [
            for (var i = 1; i <= itemCount; i++)
              LocalMediaItem(
                id: 'item-$i',
                libraryId: '',
                title: 'E${i.toString().padLeft(2, '0')}',
                location: videos[i - 1].path,
                sizeBytes: 1024 * i,
                addedAt: 1,
              ),
          ],
        );
        fixture.libraryId = library.id;
      }
      return fixture;
    });
    return built!;
  }

  Widget host(Widget child) => LocalMediaScope(
        store: store,
        child: AnimeLibraryScope(
          store: anime,
          child: MaterialApp(
            theme: buildTheme(AppThemeVariant.light),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: child,
          ),
        ),
      );

  void dispose() {
    store.dispose();
    anime.dispose();
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException {
      // 临时目录清理失败不该影响测试结论(Windows 上偶尔还被句柄占着)。
    }
  }
}
