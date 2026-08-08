import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_data.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_selection_bar.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_tools_sheet.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selection bar exposes copy highlight note and search actions',
      (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(_app(
      NovelReaderSelectionBar(
        selection: _selection(),
        onCopy: () => calls.add('copy'),
        onHighlight: () => calls.add('highlight'),
        onNote: () => calls.add('note'),
        onSearch: () => calls.add('search'),
        backgroundColor: const Color(0xe6ffffff),
        foregroundColor: const Color(0xff202124),
      ),
    ));

    for (final key in const [
      'novel-selection-copy',
      'novel-selection-highlight',
      'novel-selection-note',
      'novel-selection-search',
    ]) {
      await tester.tap(find.byKey(Key(key)));
    }

    expect(calls, ['copy', 'highlight', 'note', 'search']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tools sheet switches directory bookmarks and notes tabs',
      (tester) async {
    final bookmark = NovelBookmark.create(
      bookKey: 'book-key',
      locator: _locator(),
      excerpt: '书签摘要',
      createdAt: 10,
    );
    final annotation = NovelAnnotation.create(
      bookKey: 'book-key',
      range: NovelAnnotationRange.fromSelection(_selection()),
      colorId: 'yellow',
      note: '待确认的笔记',
      createdAt: 11,
    );
    final data = NovelReaderBookData(
      bookKey: 'book-key',
      bookmarks: {bookmark.id: bookmark},
      annotations: {annotation.id: annotation},
    );
    final calls = <String>[];
    await tester.pumpWidget(_app(
      SizedBox(
        width: 420,
        height: 700,
        child: NovelReaderToolsSheet(
          chapters: const [
            NovelChapter(id: 'chapter-1', title: '第一章'),
            NovelChapter(id: 'chapter-2', title: '第二章'),
          ],
          currentChapterId: 'chapter-1',
          data: data,
          unresolvedAnnotationIds: {annotation.id},
          initialTab: NovelReaderToolsTab.directory,
          onChapterSelected: (chapter) => calls.add('chapter:${chapter.id}'),
          onBookmarkSelected: (value) => calls.add('bookmark:${value.id}'),
          onAnnotationSelected: (value) => calls.add('annotation:${value.id}'),
          onEditAnnotation: (value) => calls.add('edit:${value.id}'),
          onDeleteBookmark: (value) => calls.add('delete-bookmark:${value.id}'),
          onDeleteAnnotation: (value) => calls.add('delete:${value.id}'),
        ),
      ),
    ));

    await tester.tap(find.text('第二章'));
    await tester.tap(find.byKey(const Key('novel-tools-tab-bookmarks')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书签摘要'));
    await tester.tap(find.byKey(const Key('novel-tools-tab-notes')));
    await tester.pumpAndSettle();

    expect(find.text('待重新定位'), findsOneWidget);
    expect(find.text('待确认的笔记'), findsOneWidget);
    await tester.tap(find.text('待确认的笔记'));

    expect(calls.first, 'chapter:chapter-2');
    expect(calls, contains('bookmark:${bookmark.id}'));
    expect(calls, contains('annotation:${annotation.id}'));
  });

  testWidgets('selection actions are localized and keyboard reachable',
      (tester) async {
    var copies = 0;
    await tester.pumpWidget(_app(
      NovelReaderSelectionBar(
        selection: _selection(),
        onCopy: () => copies++,
        onHighlight: () {},
        onNote: () {},
        onSearch: () {},
        backgroundColor: const Color(0xe6ffffff),
        foregroundColor: const Color(0xff202124),
      ),
      locale: const Locale('en'),
    ));

    for (final label in const ['Copy', 'Highlight', 'Note', 'Search in book']) {
      expect(find.byTooltip(label), findsOneWidget);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(copies, 1);
  });

  testWidgets('reader tools tabs and empty states are localized',
      (tester) async {
    await tester.pumpWidget(_app(
      SizedBox(
        width: 360,
        height: 600,
        child: NovelReaderToolsSheet(
          chapters: const [],
          currentChapterId: '',
          data: NovelReaderBookData.empty('book-key'),
          unresolvedAnnotationIds: const {},
          initialTab: NovelReaderToolsTab.bookmarks,
          onChapterSelected: (_) {},
          onBookmarkSelected: (_) {},
          onAnnotationSelected: (_) {},
          onEditAnnotation: (_) {},
          onDeleteBookmark: (_) {},
          onDeleteAnnotation: (_) {},
        ),
      ),
      locale: const Locale('en'),
    ));

    expect(find.text('Directory'), findsOneWidget);
    expect(find.text('Bookmarks'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('No bookmarks yet'), findsOneWidget);
  });
}

Widget _app(Widget home, {Locale locale = const Locale('zh')}) {
  return MaterialApp(
    theme: buildTheme(AppThemeVariant.light),
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(body: Center(child: home)),
  );
}

NovelSelection _selection() => NovelSelection(
      text: '选中的正文',
      start: _locator(),
      end: _locator(charOffset: 9),
    );

NovelLocator _locator({int charOffset = 2}) => NovelLocator(
      chapterId: 'chapter-1',
      blockId: 'block-1',
      charOffset: charOffset,
      quote: '选中的正文',
      prefix: '前文',
      suffix: '后文',
      fraction: .25,
    );
