import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_paginator.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_render_document.dart';
import 'package:dream_manga_reader/features/novel/novel_native_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NovelPaginationResult layout(Size size) => NovelPaginator.paginate(
        document: NovelRenderDocumentParser.parse(
          NovelDocument(
            format: NovelDocumentFormat.text,
            content: List.generate(
              12,
              (index) => '第${index + 1}段 ${List.filled(36, '正文内容').join()}',
            ).join('\n'),
          ),
        ),
        viewport: size,
        style: const NovelPageStyle(
          fontSize: 18,
          lineHeight: 1.6,
          paragraphSpacing: 10,
          firstLineIndent: 2,
          pagePadding: EdgeInsets.fromLTRB(26, 30, 26, 34),
        ),
      );

  Future<void> pumpReader(
    WidgetTester tester,
    Size size,
    NovelPaginationResult pagination,
  ) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: NovelNativePageView(
                pagination: pagination,
                spreadIndex: 0,
                canvasColor: const Color(0xffd7d2c4),
                pageColor: const Color(0xfff7f1df),
                textColor: const Color(0xff25231f),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders a single right leaf on phone layouts', (tester) async {
    const size = Size(420, 760);
    final pagination = layout(size);
    await pumpReader(tester, size, pagination);

    expect(find.byKey(const Key('novel-native-page-view')), findsOneWidget);
    expect(find.byKey(const Key('novel-leaf-left')), findsNothing);
    expect(find.byKey(const Key('novel-leaf-right')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('novel-leaf-right'))),
      pagination.leafRects.single,
    );
  });

  testWidgets('renders two separately addressable leaves on wide layouts',
      (tester) async {
    const size = Size(1180, 760);
    final pagination = layout(size);
    await pumpReader(tester, size, pagination);

    expect(find.byKey(const Key('novel-leaf-left')), findsOneWidget);
    expect(find.byKey(const Key('novel-leaf-right')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('novel-leaf-left'))),
      pagination.leafRects[0],
    );
    expect(
      tester.getRect(find.byKey(const Key('novel-leaf-right'))),
      pagination.leafRects[1],
    );
    expect(find.byKey(const Key('novel-book-spine')), findsOneWidget);
  });

  testWidgets('exposes painted page text and page number to semantics',
      (tester) async {
    const size = Size(420, 760);
    final pagination = layout(size);
    await pumpReader(tester, size, pagination);

    final semantics = tester.getSemantics(
      find.byKey(const Key('novel-leaf-right')),
    );
    expect(semantics.label, contains('第1段'));
    expect(semantics.value, '1');
  });

  testWidgets('uses the selected canvas and page colors without a black layer',
      (tester) async {
    const size = Size(420, 760);
    await pumpReader(tester, size, layout(size));

    final canvas = tester.widget<ColoredBox>(
      find.byKey(const Key('novel-page-canvas-color')),
    );
    expect(canvas.color, const Color(0xffd7d2c4));
    final leaf = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byKey(const Key('novel-leaf-right')),
        matching: find.byKey(const Key('novel-page-paper-color')),
      ),
    );
    expect(leaf.color, const Color(0xfff7f1df));
  });
}
