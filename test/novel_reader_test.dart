import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/features/novel/novel_document_view.dart';
import 'package:dream_manga_reader/features/novel/novel_reader_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeController implements NovelDocumentController {
  _FakeController({
    this.locator = const NovelLocator(chapterId: 'c1'),
  });

  NovelLocator locator;
  NovelLocator? lastRestored;
  String? loadedChapterId;
  NovelReaderPreferences? appliedPreferences;

  @override
  ValueChanged<NovelReaderCommand>? onCommand;

  @override
  ValueChanged<NovelLocator>? onLocatorChanged;

  @override
  Future<void> applyPreferences(NovelReaderPreferences preferences) async {
    appliedPreferences = preferences;
  }

  @override
  Future<NovelLocator> captureLocator() async => locator;

  @override
  Future<void> loadChapter(
    String chapterId,
    NovelDocument document,
    NovelReaderPreferences preferences,
  ) async {
    loadedChapterId = chapterId;
    if (locator.chapterId != chapterId) {
      locator = NovelLocator(chapterId: chapterId);
    }
  }

  @override
  Future<bool> nextPage() async => true;

  @override
  Future<bool> previousPage() async => true;

  @override
  Future<void> restoreLocator(NovelLocator value) async {
    lastRestored = value;
    locator = value;
  }
}

Future<Widget> _readerHarness(_FakeController controller) async {
  final store = NovelLibraryStore();
  await store.load();
  return MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: NovelLibraryScope(
      store: store,
      child: NovelReaderPage(
        novel: const Novel(id: 'n1', title: '测试小说'),
        chapters: const [
          NovelChapter(id: 'c1', title: '第一章'),
          NovelChapter(id: 'c2', title: '第二章'),
        ],
        initialIndex: 0,
        libraryKey: 'remote:s:n1',
        controller: controller,
        documentViewBuilder: (_, __) => const ColoredBox(color: Colors.black),
        loadDocument: (chapter) async => NovelDocument(
          format: NovelDocumentFormat.html,
          content: '<p>${chapter.title}</p>',
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('mode and typography changes preserve locator', (tester) async {
    final controller = _FakeController(
      locator: const NovelLocator(
        chapterId: 'c1',
        blockId: 'dmr-7',
        fraction: .3,
      ),
    );
    await tester.pumpWidget(await _readerHarness(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('novel-reader-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连续滚动'));
    await tester.pumpAndSettle();

    expect(controller.appliedPreferences?.mode, NovelReaderMode.scroll);
    expect(controller.lastRestored?.blockId, 'dmr-7');
    expect(controller.lastRestored?.fraction, .3);
  });

  testWidgets('directory selection loads the selected chapter', (tester) async {
    final controller = _FakeController();
    await tester.pumpWidget(await _readerHarness(controller));
    await tester.pumpAndSettle();
    expect(controller.loadedChapterId, 'c1');

    await tester.tap(find.byKey(const Key('novel-reader-directory')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二章'));
    await tester.pumpAndSettle();

    expect(controller.loadedChapterId, 'c2');
  });

  test('reader HTML shell sanitizes HTML and escapes plain text', () {
    final html = buildNovelReaderHtml(NovelDocument(
      format: NovelDocumentFormat.html,
      content: '<p onclick="bad()">正文</p><script>bad()</script>',
    ));
    final text = buildNovelReaderHtml(NovelDocument(
      format: NovelDocumentFormat.text,
      content: '<script>只是文字</script>',
    ));

    expect(html, contains('Content-Security-Policy'));
    expect(html, contains("connect-src 'none'"));
    expect(html, isNot(contains('onclick')));
    expect(html, isNot(contains('<script>bad()')));
    expect(text, contains('&lt;script&gt;只是文字&lt;/script&gt;'));
    expect(
      novelReaderBridgeScript,
      contains('calc((100vw - 760px) / 2)'),
    );
    expect(
        novelReaderBridgeScript, contains('img{max-width:100%;height:auto}'));
    expect(
      novelReaderBridgeScript,
      contains("closest?.('a,button,input,textarea,select,[contenteditable]')"),
    );
    expect(novelReaderBridgeScript, contains("addEventListener('wheel'"));
    expect(novelReaderBridgeScript, contains('{passive:false}'));
  });
}
