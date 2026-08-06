import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/page_image_data.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/features/reader/reader_page.dart';
import 'package:dream_manga_reader/features/reader/retryable_reader_network_image.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';

const _onePixelPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

/// 回归:Base64 内联页要在**阅读器里真的画出来**。
///
/// 旧 bug:渲染路径 `_image()` 只分 http / 非 http 两支,`data:` URI 不以 http
/// 开头 → 被当成本地文件名去 `Image.file` 打开 → 整页破图。当时单测只断言了
/// `readerPageImageProvider` 返回 MemoryImage,而那个函数只被预加载和宽高比
/// 探测用到,渲染根本没走它,所以测试全绿、功能是坏的。
void main() {
  Widget harness(LibraryStore store, List<PageImage> pages) => LibraryScope(
        store: store,
        child: MaterialApp(
          theme: buildTheme(AppThemeVariant.light),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: ReaderPage(
            source: _FakeSource(pages),
            manga: const Manga(id: 'm', title: '测试'),
            chapters: const [Chapter(id: 'c', name: '第1话')],
            index: 0,
          ),
        ),
      );

  testWidgets('a Base64 page renders from memory, not as a file path',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();

    await tester.pumpWidget(
      harness(store, const [PageImage(index: 0, url: _onePixelPng)]),
    );
    await tester.pumpAndSettle();

    final providers = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .toList();
    expect(providers, isNotEmpty);
    expect(providers.whereType<MemoryImage>(), isNotEmpty,
        reason: 'Base64 页应当以 MemoryImage 渲染');
    expect(providers.whereType<FileImage>(), isEmpty,
        reason: 'data: URI 不该被当成文件路径');
    expect(find.byType(RetryableReaderNetworkImage), findsNothing);
    expect(tester.takeException(), isNull);
    store.dispose();
  });

  testWidgets('a local file page still renders from the file', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();

    await tester.pumpWidget(
      harness(store, const [PageImage(index: 0, url: '/tmp/downloaded/0.img')]),
    );
    await tester.pumpAndSettle();

    final providers = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .toList();
    expect(providers.whereType<FileImage>(), isNotEmpty);
    expect(find.byType(RetryableReaderNetworkImage), findsNothing);
    store.dispose();
  });

  testWidgets('only HTTP pages use the retryable network image',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    await store.load();

    await tester.pumpWidget(
      harness(store, const [
        PageImage(index: 0, url: 'https://example.test/page.png'),
      ]),
    );
    await tester.pump();

    expect(find.byType(RetryableReaderNetworkImage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  test('decoding the same page twice reuses the same byte buffer', () {
    // MemoryImage 按 bytes 的**实例**判等。每次 build 重新解码就会生成新实例,
    // Flutter 的 ImageCache 永远命不中 → 每帧把整张图重解一遍。
    final first = decodePageImageDataUri(_onePixelPng);
    final second = decodePageImageDataUri(_onePixelPng);

    expect(identical(first.bytes, second.bytes), isTrue);
    expect(MemoryImage(first.bytes) == MemoryImage(second.bytes), isTrue);
  });
}

class _FakeSource implements MangaSource {
  _FakeSource(this.pages);
  final List<PageImage> pages;

  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  String get lang => 'zh';
  @override
  String get baseUrl => '';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;
  @override
  List<FilterDef> get filters => const [];
  @override
  void dispose() {}
  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) async =>
      pages;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
