import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:dream_manga_reader/features/novel/novel_document_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bridge exposes paging anchor and selection contracts', () {
    for (final contract in const [
      '__dmrMetrics',
      '__dmrShowPage',
      '__dmrCaptureAnchor',
      '__dmrRestoreAnchor',
      '__dmrSelection',
    ]) {
      expect(novelReaderBridgeScript, contains(contract));
    }
  });

  test('page indexes clamp to the available page range', () {
    expect(clampNovelPageIndex(-2, 5), 0);
    expect(clampNovelPageIndex(2, 5), 2);
    expect(clampNovelPageIndex(8, 5), 4);
    expect(clampNovelPageIndex(8, 0), 0);
  });

  test('page metrics parse and clamp untrusted bridge values', () {
    final metrics = parseNovelPageMetrics({
      'pageCount': 3,
      'currentPageIndex': 9,
      'viewportWidth': 1080,
      'viewportHeight': 1920,
      'devicePixelRatio': 2.75,
      'layoutFingerprint': 'layout-v2',
      'visibleTextLength': 0,
      'fontLoadFailed': true,
    });

    expect(
      metrics,
      const NovelPageMetrics(
        pageCount: 3,
        currentPageIndex: 2,
        viewport: NovelViewport(
          width: 1080,
          height: 1920,
          devicePixelRatio: 2.75,
        ),
        layoutFingerprint: 'layout-v2',
        visibleTextLength: 0,
        fontLoadFailed: true,
      ),
    );
    expect(metrics!.visibleTextLength, 0);
    expect(metrics.fontLoadFailed, isTrue);
    expect(parseNovelPageMetrics(null), isNull);
  });

  test('semantic locator parser retains bounded context anchors', () {
    final locator = parseNovelLocatorValue(
      {
        'blockId': 'dmr-7',
        'charOffset': 42,
        'quote': '目标文字',
        'prefix': List.filled(40, '前').join(),
        'suffix': List.filled(40, '后').join(),
        'fraction': .35,
      },
      chapterId: 'chapter-1',
    );

    expect(locator?.blockId, 'dmr-7');
    expect(locator?.charOffset, 42);
    expect(locator?.quote, '目标文字');
    expect(locator?.prefix, List.filled(32, '前').join());
    expect(locator?.suffix, List.filled(32, '后').join());
    expect(locator?.fraction, .35);
  });

  test('selection parser maps both endpoints without chapter text', () {
    final selection = parseNovelSelectionValue(
      {
        'text': '被选中的文字',
        'start': {
          'blockId': 'dmr-1',
          'charOffset': 3,
          'quote': '被选中',
        },
        'end': {
          'blockId': 'dmr-2',
          'charOffset': 5,
          'quote': '的文字',
        },
        'rect': {'left': 12, 'top': 34, 'width': 56, 'height': 20},
      },
      chapterId: 'chapter-1',
    );

    expect(selection?.text, '被选中的文字');
    expect(selection?.start.blockId, 'dmr-1');
    expect(selection?.start.charOffset, 3);
    expect(selection?.end.blockId, 'dmr-2');
    expect(selection?.end.charOffset, 5);
    expect(selection?.rect, const NovelSelectionRect(12, 34, 56, 20));
  });

  test('annotation bridge uses layout-neutral highlights and recovery order',
      () {
    expect(novelReaderBridgeScript, contains('window.__dmrApplyAnnotations'));
    expect(novelReaderBridgeScript, contains('CSS.highlights'));
    expect(novelReaderBridgeScript, contains('resolveStoredRange'));
    expect(novelReaderBridgeScript, contains('directRange'));
    expect(novelReaderBridgeScript, contains('quoteRange'));
    expect(novelReaderBridgeScript, contains('window.__dmrClearSelection'));
    expect(novelReaderBridgeScript, contains('window.__dmrShowSearchResult'));
    expect(novelReaderBridgeScript, contains('end.suffix ='));
  });

  test('annotation quote fallback maps ranges across document blocks', () {
    expect(novelReaderBridgeScript, contains('const documentTextMap'));
    expect(novelReaderBridgeScript, contains('pointAtDocumentOffset'));
    expect(novelReaderBridgeScript, contains('startDocumentOffset'));
    expect(novelReaderBridgeScript, contains('endDocumentOffset'));
    expect(
      novelReaderBridgeScript,
      contains(
          'document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)'),
    );
  });

  test('sanitized documents assign stable IDs to common text blocks', () {
    final html = buildNovelReaderHtml(
      NovelDocument(
        format: NovelDocumentFormat.html,
        content: '<h2>标题</h2><div><p>正文</p><ul><li>条目</li></ul></div>',
      ),
      chapterId: 'chapter-1',
    );

    expect(html, contains('data-dmr-block="dmr-0"'));
    expect(html, contains('data-dmr-block="dmr-1"'));
    expect(html, contains('data-dmr-block="dmr-2"'));
  });
}
