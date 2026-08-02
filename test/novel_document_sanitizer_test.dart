import 'package:dream_manga_reader/core/novel/novel_document_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('removes executable content and keeps reading markup', () {
    final html = NovelDocumentSanitizer.sanitize(
      '<script>alert(1)</script>'
      '<p onclick="x()">字<ruby>词<rt>ci</rt></ruby>'
      '<img src="../images/a.jpg"></p>',
      baseUrl: Uri.parse('https://example.com/book/chapter/'),
    );

    expect(html, isNot(contains('script')));
    expect(html, isNot(contains('onclick')));
    expect(html, contains('<ruby>'));
    expect(html, contains('https://example.com/book/images/a.jpg'));
    expect(html, contains('data-dmr-block="dmr-0"'));
  });

  test('drops dangerous URLs and active or unknown elements', () {
    final html = NovelDocumentSanitizer.sanitize(
      '<a href="javascript:x()">x</a>'
      '<a href="data:text/html,<script>x()</script>">bad</a>'
      '<iframe src="https://bad.example">frame</iframe>'
      '<form><input value="secret"></form>'
      '<custom-element>保留文字</custom-element>',
    );

    expect(html, isNot(contains('javascript:')));
    expect(html, isNot(contains('data:text/html')));
    expect(html, isNot(contains('iframe')));
    expect(html, isNot(contains('form')));
    expect(html, isNot(contains('input')));
    expect(html, isNot(contains('custom-element')));
    expect(html, contains('保留文字'));
  });

  test('stable block IDs and safe internal anchors survive repeated runs', () {
    const source = '<h1 id="top">标题</h1><p>一</p><p>二</p>';

    final first = NovelDocumentSanitizer.sanitize(source);
    final second = NovelDocumentSanitizer.sanitize(source);

    expect(second, first);
    expect(first, contains('id="top"'));
    expect(first, contains('data-dmr-block="dmr-0"'));
    expect(first, contains('data-dmr-block="dmr-1"'));
    expect(first, contains('data-dmr-block="dmr-2"'));
  });
}
