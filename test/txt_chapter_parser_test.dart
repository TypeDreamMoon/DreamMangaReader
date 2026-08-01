import 'dart:convert';

import 'package:dream_manga_reader/core/novel/import/txt_chapter_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes padded, Chinese-numbered and volume headings', () {
    final result = TxtChapterParser.parse('''
书名
作者：作者甲
第一卷 起点

第0001章 开始
正文一。

第二章 继续
正文二。
''');

    expect(result.chapters.map((chapter) => chapter.title), [
      '第0001章 开始',
      '第二章 继续',
    ]);
    expect(result.chapters.map((chapter) => chapter.number), [1, 2]);
    expect(result.volumes.single.title, '第一卷 起点');
    expect(result.volumes.single.chapters.length, 2);
    expect(result.chapters.last.volumeTitle, '第一卷 起点');
    expect(result.metadata.title, '书名');
    expect(result.metadata.author, '作者甲');
    expect(result.metadata.preface, contains('作者：作者甲'));
  });

  test('does not treat prose beginning with 第二部 as a heading', () {
    final result = TxtChapterParser.parse('''
第一章 开始
第二部，我还没想好主角和切入，但这里仍然是正文：
后续正文。
第二章 继续
''');

    expect(result.chapters.length, 2);
    expect(result.volumes, isEmpty);
    expect(result.chapters.map((chapter) => chapter.title), [
      '第一章 开始',
      '第二章 继续',
    ]);
  });

  test('falls back to one chapter when confidence is insufficient', () {
    final result = TxtChapterParser.parse('没有目录的短篇正文。');

    expect(result.chapters.single.title, '正文');
    expect(result.chapters.single.offset, 0);
    expect(result.chapters.single.contentOffset, 0);
    expect(
      result.chapters.single.endOffset,
      utf8.encode('没有目录的短篇正文。').length,
    );
    expect(result.volumes, isEmpty);
  });

  test('offsets address normalized UTF-8 bytes rather than source bytes', () {
    final result = TxtChapterParser.parse(
      '书名\r\n\r\n第一章 开始\r正文一。\r\n\r\n第二章 继续\r\n正文二。',
    );
    final secondHeading = result.normalizedText.indexOf('第二章 继续');

    expect(result.normalizedText, isNot(contains('\r')));
    expect(
      result.chapters.last.offset,
      utf8.encode(result.normalizedText.substring(0, secondHeading)).length,
    );
    expect(
      result.chapters.first.endOffset,
      result.chapters.last.offset,
    );
  });

  test('accepts bounded special headings and rejects sentence-like long lines',
      () {
    final longLine = '第九章 ${List.filled(81, '长').join()}';
    final result = TxtChapterParser.parse('''
序章
开场正文。

第一章 正文
内容。

第二部，我还没想好……
$longLine

尾声
收束正文。
''');

    expect(result.chapters.map((chapter) => chapter.title), [
      '序章',
      '第一章 正文',
      '尾声',
    ]);
    expect(result.volumes, isEmpty);
  });
}
