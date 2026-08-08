import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_render_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NovelRenderDocumentParser', () {
    test('keeps TXT paragraphs and intentional blank lines in source order',
        () {
      final result = NovelRenderDocumentParser.parse(
        NovelDocument(
          format: NovelDocumentFormat.text,
          content: '第一段\r\n\r\n第二段\n第三段',
        ),
      );

      expect(
        result.blocks.map((block) => block.kind),
        [
          NovelRenderBlockKind.paragraph,
          NovelRenderBlockKind.spacer,
          NovelRenderBlockKind.paragraph,
          NovelRenderBlockKind.paragraph,
        ],
      );
      expect(
        result.blocks.map((block) => block.id),
        ['dmr-0', 'dmr-1', 'dmr-2', 'dmr-3'],
      );
      expect(result.plainText, '第一段\n\n第二段\n第三段');
    });

    test('normalizes common EPUB HTML into semantic reading blocks', () {
      final result = NovelRenderDocumentParser.parse(
        NovelDocument(
          format: NovelDocumentFormat.html,
          content: '''
            <h2>第一章</h2>
            <p>普通<strong>粗体</strong><em>斜体</em></p>
            <blockquote>引用内容</blockquote>
            <ol start="3"><li>第三项</li><li>第四项</li></ol>
            <script>不应出现</script>
          ''',
        ),
      );

      expect(
        result.blocks.map((block) => block.kind),
        [
          NovelRenderBlockKind.heading,
          NovelRenderBlockKind.paragraph,
          NovelRenderBlockKind.quote,
          NovelRenderBlockKind.listItem,
          NovelRenderBlockKind.listItem,
        ],
      );
      expect(result.blocks[0].headingLevel, 2);
      expect(result.blocks[1].plainText, '普通粗体斜体');
      expect(result.blocks[1].inlines[1].bold, isTrue);
      expect(result.blocks[1].inlines[2].italic, isTrue);
      expect(result.blocks[3].marker, '3.');
      expect(result.blocks[4].marker, '4.');
      expect(result.plainText, isNot(contains('不应出现')));
    });

    test('preserves ruby metadata without duplicating pronunciation', () {
      final result = NovelRenderDocumentParser.parse(
        NovelDocument(
          format: NovelDocumentFormat.html,
          content: '<p><ruby>漢<rt>かん</rt></ruby>字</p>',
        ),
      );

      expect(result.blocks.single.plainText, '漢字');
      expect(result.blocks.single.inlines.first.text, '漢');
      expect(result.blocks.single.inlines.first.ruby, 'かん');
    });

    test('retains safe images with resolved source and alt text', () {
      final result = NovelRenderDocumentParser.parse(
        NovelDocument(
          format: NovelDocumentFormat.html,
          baseUrl: 'https://example.com/books/chapter.xhtml',
          content: '<p>插图前</p><img src="../img/1.png" alt="插图"><p>插图后</p>',
        ),
      );

      expect(result.blocks[1].kind, NovelRenderBlockKind.image);
      expect(result.blocks[1].imageSource, 'https://example.com/img/1.png');
      expect(result.blocks[1].imageAlt, '插图');
      expect(result.blocks[1].id, 'dmr-image-0');
    });

    test('uses sanitizer block identifiers as portable locator anchors', () {
      final result = NovelRenderDocumentParser.parse(
        NovelDocument(
          format: NovelDocumentFormat.html,
          content: '<p id="source-p">第一段</p><p>第二段</p>',
        ),
      );

      expect(result.blocks.map((block) => block.id), ['dmr-0', 'dmr-1']);
      expect(result.blocks.first.sourceId, 'source-p');
    });
  });
}
