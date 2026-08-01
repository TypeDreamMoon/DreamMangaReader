# DreamMangaReader Novel Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add a complete, isolated novel domain to DreamMangaReader with external script sources, local TXT/EPUB import, separate library/download state, safe reflowable reading, offline chapters, and metadata/progress synchronization on Windows and Android.

**Architecture:** Keep the existing manga and anime models intact. Add Novel, NovelChapter, NovelDocument and NovelSource beside them; reuse the current JS host, networking, source repository, theme and platform services. Store novel library/download data in independent stores, render sanitized text/EPUB content through the existing cross-platform WebView, and extend backup/sync contracts without uploading book files.

**Tech Stack:** Flutter, Dart 3.6+, Material 3, flutter_inappwebview, Dio, SharedPreferences, file_picker, archive, epubx 4.0.0, charset 2.0.1, charset_converter 2.3.0, html, crypto, path_provider, flutter_test.

---

## File Structure

- lib/core/novel/models.dart: novel, chapter, document, locator and imported-book contracts.
- lib/core/novel/novel_source.dart: online novel source interface.
- lib/core/novel/novel_document_sanitizer.dart: allowlist HTML sanitizer and URL resolver.
- lib/core/novel/novel_document_cache.dart: chapter document/resource persistence.
- lib/core/novel/import/novel_encoding.dart: BOM/UTF/GB18030/Big5 decoding.
- lib/core/novel/import/txt_chapter_parser.dart: scored TXT chapter recognition.
- lib/core/novel/import/txt_novel_importer.dart: TXT preview and transactional import.
- lib/core/novel/import/epub_preflight.dart: ZIP path/size/ratio safety checks.
- lib/core/novel/import/epub_novel_importer.dart: EPUB metadata, spine, TOC and resource import.
- lib/app/novel_library_store.dart: novel entries, favorites, history, progress and reader settings.
- lib/app/novel_download_store.dart: online chapter download queue and offline index.
- lib/features/novel/novel_browser.dart: online discovery and mixed-source search.
- lib/features/novel/novel_detail_page.dart: detail, chapters, source switch and downloads.
- lib/features/novel/novel_reader_page.dart: reading shell and chapter navigation.
- lib/features/novel/novel_document_view.dart: WebView document/pagination bridge.
- lib/features/novel/novel_reader_settings_sheet.dart: typography and theme controls.
- lib/features/novel/novel_import_sheet.dart: local file picker, preview and confirmation.
- lib/features/novel/novel_library_view.dart: novel shelf, continue-reading and local books.
- lib/features/novel/novel_downloads_view.dart: novel offline content management.
- lib/features/novel/novel_cover.dart: remote, EPUB and generated TXT covers.

## Task 1: Novel Domain Contracts

**Files:**
- Create: lib/core/novel/models.dart
- Create: lib/core/novel/novel_source.dart
- Create: test/novel_models_test.dart
- Modify: lib/core/source/source_registry.dart

- [ ] **Step 1: Write failing model tests**

~~~dart
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote and local novel keys never collide', () {
    expect(NovelIdentity.remote('s', 'n').key, 'remote:s:n');
    expect(NovelIdentity.local('abc').key, 'local:abc');
  });

  test('document rejects unsupported format and unsafe empty identity', () {
    expect(
      () => NovelDocument(format: NovelDocumentFormat.html, content: ''),
      throwsArgumentError,
    );
    expect(
      NovelLocator(chapterId: 'c1', blockId: 'p12', fraction: 1.7).fraction,
      1.0,
    );
  });

  test('models preserve volume and chapter navigation metadata', () {
    const chapter = NovelChapter(
      id: 'c1',
      title: '第一章',
      number: 1,
      volumeId: 'v1',
      volumeTitle: '第一卷',
    );
    expect(chapter.volumeTitle, '第一卷');
  });
}
~~~

- [ ] **Step 2: Run flutter test test/novel_models_test.dart**

Expected: FAIL because core/novel/models.dart does not exist.

- [ ] **Step 3: Implement immutable contracts**

~~~dart
enum NovelStatus { unknown, ongoing, completed, hiatus, cancelled }
enum NovelOrigin { remote, localTxt, localEpub }
enum NovelDocumentFormat { text, html }

class NovelIdentity {
  const NovelIdentity._(this.key);
  factory NovelIdentity.remote(String sourceId, String novelId) =>
      NovelIdentity._('remote:' + sourceId + ':' + novelId);
  factory NovelIdentity.local(String sha256) =>
      NovelIdentity._('local:' + sha256.toLowerCase());
  final String key;
}

class Novel {
  const Novel({
    required this.id,
    required this.title,
    this.url,
    this.cover,
    this.authors = const [],
    this.genres = const [],
    this.description,
    this.status = NovelStatus.unknown,
    this.updatedAt,
  });
  final String id;
  final String title;
  final String? url;
  final String? cover;
  final List<String> authors;
  final List<String> genres;
  final String? description;
  final NovelStatus status;
  final int? updatedAt;
}
~~~

Add NovelChapter, NovelVolume, NovelDocument, NovelLocator and ImportedNovelPreview. Reuse the existing generic Paged<T> contract for novel result pages. NovelDocument accepts non-empty text/HTML, an optional base URL and a resource map. NovelLocator clamps fraction to 0..1.

- [ ] **Step 4: Add the independent source interface**

~~~dart
abstract interface class NovelSource {
  String get id;
  String get name;
  List<FilterDef> get filters;
  List<SourceSection> get sections;

  Future<Paged<Novel>> getNovelDiscovery(
    int page, {
    Map<String, Object?>? filters,
  });
  Future<Paged<Novel>> getNovelSection(String sectionId, int page);
  Future<Paged<Novel>> getNovelSearch(
    String query,
    int page, {
    Map<String, Object?>? filters,
  });
  Future<Novel> getNovelDetail(String novelId);
  Future<Paged<NovelChapter>> getNovelChapters(String novelId, {int? page});
  Future<NovelDocument> getNovelDocument(String novelId, String chapterId);
  void dispose();
}
~~~

Add SourceMeta.isNovel and SourceMeta.isManga getters. Do not alter MangaSource signatures.

- [ ] **Step 5: Run tests and analysis**

~~~powershell
flutter test test/novel_models_test.dart
dart analyze lib/core/novel lib/core/source/source_registry.dart
~~~

Expected: PASS with no findings.

- [ ] **Step 6: Commit**

~~~powershell
git add lib/core/novel lib/core/source/source_registry.dart test/novel_models_test.dart
git commit -m "feat: add novel domain contracts"
~~~

## Task 2: Script Novel Source Protocol

**Files:**
- Modify: lib/core/script/script_source.dart
- Modify: lib/core/source/source_registry.dart
- Create: test/novel_script_source_test.dart

- [ ] **Step 1: Write a failing script-source contract test**

~~~dart
class FakeHttp implements HttpService {
  @override
  Future<HostResponse> fetch(HostRequest request) async => const HostResponse(
        status: 200,
        headers: {},
        body: '{"ok":true}',
      );
}

test('novel script decodes discovery, chapters and HTML document', () async {
  final source = ScriptSource(
    engine: JsEngine(),
    http: FakeHttp(),
    scriptCode: novelFixtureScript,
  );
  final novels = await source.getNovelSearch('测试', 1);
  final chapters = await source.getNovelChapters('n1');
  final document = await source.getNovelDocument('n1', 'c1');
  expect(novels.items.single.title, '测试小说');
  expect(chapters.items.single.volumeTitle, '第一卷');
  expect(document.format, NovelDocumentFormat.html);
  expect(document.content, contains('<p>'));
  source.dispose();
});
~~~

The fixture implements the existing prepareSearch/handleSearch, prepareMangaInfo/handleMangaInfo, prepareChapterList/handleChapterList and prepareChapter/handleChapter names. handleChapter returns one object with format, content, baseUrl and resources.

- [ ] **Step 2: Run flutter test test/novel_script_source_test.dart**

Expected: FAIL because ScriptSource does not implement NovelSource.

- [ ] **Step 3: Implement NovelSource on ScriptSource**

Change the declaration to implement both MangaSource and NovelSource. Add novel-specific decoding methods whose names do not conflict with MangaSource. Reuse the existing private _run transport and JS host.

~~~dart
@override
Future<NovelDocument> getNovelDocument(
  String novelId,
  String chapterId,
) => _run(
  'prepareChapter',
  [novelId, chapterId],
  'handleChapter',
  (json) {
    final map = (json as Map).cast<String, dynamic>();
    return NovelDocument(
      format: map['format'] == 'text'
          ? NovelDocumentFormat.text
          : NovelDocumentFormat.html,
      content: map['content'] as String,
      baseUrl: map['baseUrl'] as String?,
      resources: (map['resources'] as Map?)?.cast<String, String>() ?? const {},
    );
  },
);
~~~

Add _toNovel and _toNovelChapter decoders. Preserve the existing manga, anime and login paths byte-for-byte except required imports/interface declaration.

- [ ] **Step 4: Add buildNovelSource**

~~~dart
NovelSource buildNovelSource(SourceMeta meta) {
  if (!meta.isNovel) {
    throw ArgumentError.value(meta.kind, 'meta.kind', 'expected novel');
  }
  return ScriptSource(
    engine: JsEngine(),
    http: meta.useWebView
        ? WebViewHttpService(userAgent: mobileUserAgent)
        : DioHttpService(),
    webHttp: WebViewHttpService(userAgent: desktopUserAgent),
    scriptCode: meta.script,
  );
}
~~~

Expose the existing user-agent constants with private helper factories rather than duplicating strings.

- [ ] **Step 5: Run focused regression tests**

~~~powershell
flutter test test/novel_script_source_test.dart test/bili_wbi_test.dart
dart analyze lib/core/script/script_source.dart lib/core/source/source_registry.dart
~~~

Expected: PASS.

- [ ] **Step 6: Commit**

~~~powershell
git add lib/core/script/script_source.dart lib/core/source/source_registry.dart test/novel_script_source_test.dart
git commit -m "feat: add scriptable novel sources"
~~~

## Task 3: Per-Kind Source Selection and Source Management

**Files:**
- Modify: lib/app/source_controller.dart
- Modify: lib/features/common/source_picker.dart
- Modify: lib/features/settings/source_management_page.dart
- Modify: lib/core/source/source_repository.dart
- Modify: lib/core/sync/sync_data.dart
- Modify: lib/core/sync/sync_controller.dart
- Modify: lib/features/settings/sync_page.dart
- Create: test/source_kind_test.dart
- Modify: lib/l10n/app_zh.arb
- Modify: lib/l10n/app_zh_Hant.arb
- Modify: lib/l10n/app_en.arb
- Modify: lib/l10n/app_ja.arb

- [ ] **Step 1: Write failing source-kind tests**

~~~dart
test('source metadata recognizes all supported kinds', () {
  const manga = SourceMeta(id: 'm', name: 'M', script: '');
  const anime = SourceMeta(id: 'a', name: 'A', script: '', kind: 'anime');
  const novel = SourceMeta(id: 'n', name: 'N', script: '', kind: 'novel');
  expect(manga.isManga, true);
  expect(anime.isAnime, true);
  expect(novel.isNovel, true);
});

testWidgets('source controller keeps manga and novel selections apart',
    (tester) async {
  SharedPreferences.setMockInitialValues({
    'source.current.manga': 'm',
    'source.current.novel': 'n',
  });
  registeredSources = const [
    SourceMeta(id: 'm', name: 'M', script: ''),
    SourceMeta(id: 'n', name: 'N', script: '', kind: 'novel'),
  ];
  final controller = SourceController();
  await controller.load();
  expect(controller.currentFor('manga')?.id, 'm');
  expect(controller.currentFor('novel')?.id, 'n');
});
~~~

- [ ] **Step 2: Run flutter test test/source_kind_test.dart**

Expected: FAIL because currentFor is missing.

- [ ] **Step 3: Implement per-kind selection with migration**

Keep current as a backward-compatible manga getter/setter. Add currentFor(kind) and selectFor(kind, meta). Persist source.current.manga, source.current.anime and source.current.novel. On first load, migrate the old source.current value to source.current.manga.

- [ ] **Step 4: Extend source management**

Add a third “小说源” group that filters SourceMeta.isNovel. Change the manga group from !isAnime to isManga so novel sources cannot leak into it. When importing a single JS source, persist meta.kind from __source.meta instead of silently defaulting every imported file to manga.

Change the source picker title to depend on kind and pass kind: 'novel' from novel pages.

- [ ] **Step 5: Extend source synchronization**

Add SyncCategory.novelSources. Export/import disabledSourcesNovel and localSourcesNovel with restrictKind: 'novel'. Replace boolean anime helpers with an exact kind helper:

~~~dart
static String _kindOf(String id) {
  for (final source in registeredSources) {
    if (source.id == id) return source.kind;
  }
  return 'manga';
}
~~~

Update sync labels, signatures, append support and source summaries. Do not change existing manga/anime serialized keys.

- [ ] **Step 6: Run focused tests and localization generation**

~~~powershell
flutter gen-l10n
flutter test test/source_kind_test.dart test/sync_data_test.dart test/l10n_test.dart
dart analyze lib/app/source_controller.dart lib/core/source lib/core/sync
~~~

Expected: PASS.

- [ ] **Step 7: Commit**

~~~powershell
git add lib/app/source_controller.dart lib/features/common/source_picker.dart lib/features/settings/source_management_page.dart lib/core/source/source_repository.dart lib/core/sync lib/features/settings/sync_page.dart lib/l10n test/source_kind_test.dart test/sync_data_test.dart
git commit -m "feat: manage novel sources independently"
~~~

## Task 4: TXT Encoding and Chapter Recognition

**Files:**
- Modify: pubspec.yaml
- Create: lib/core/novel/import/novel_encoding.dart
- Create: lib/core/novel/import/txt_chapter_parser.dart
- Create: lib/core/novel/import/txt_novel_importer.dart
- Create: test/novel_encoding_test.dart
- Create: test/txt_chapter_parser_test.dart
- Create: test/txt_novel_importer_test.dart

- [ ] **Step 1: Add compatible dependencies**

Add:

~~~yaml
  charset: ^2.0.1
  charset_converter: 2.3.0
~~~

Pin charset_converter to 2.3.0 because 2.4+ requires a newer Flutter/Dart toolchain than this branch. Run flutter pub get and inspect pubspec.lock before staging.

- [ ] **Step 2: Write failing encoding tests**

~~~dart
test('BOM and strict UTF-8 win before legacy decoding', () async {
  final decoder = NovelTextDecoder(FakeLegacyDecoder());
  expect((await decoder.decode([0xef, 0xbb, 0xbf, 0x61])).text, 'a');
  expect((await decoder.decode(utf8.encode('中文'))).encoding, 'utf-8');
});

test('manual legacy encoding overrides detection', () async {
  final decoder = NovelTextDecoder(FakeLegacyDecoder(
    values: {'gb18030': '第一章 开始'},
  ));
  final result = await decoder.decode([0x81], forcedEncoding: 'gb18030');
  expect(result.text, '第一章 开始');
});
~~~

LegacyCharsetDecoder is injected. PlatformLegacyCharsetDecoder calls CharsetConverter.decode for gb18030 and big5. Pure Dart handles BOM, UTF-8 and UTF-16; charset.gbk provides a testable GBK fallback. Plausibility scoring penalizes replacement/control characters.

- [ ] **Step 3: Write failing parser tests derived from local samples**

~~~dart
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
  expect(result.chapters.map((e) => e.title), [
    '第0001章 开始',
    '第二章 继续',
  ]);
  expect(result.volumes.single.title, '第一卷 起点');
  expect(result.metadata.author, '作者甲');
});

test('does not treat prose beginning with 第二部 as a heading', () {
  final result = TxtChapterParser.parse('''
第一章 开始
第二部，我还没想好主角和切入，但这里仍然是正文：
后续正文。
第二章 继续
''');
  expect(result.chapters.length, 2);
});

test('falls back to one chapter when confidence is insufficient', () {
  final result = TxtChapterParser.parse('没有目录的短篇正文。');
  expect(result.chapters.single.title, '正文');
});
~~~

- [ ] **Step 4: Implement scored parsing**

Candidate score inputs:

- +4 for 第 + valid number + 章/回/节.
- +3 for 卷/部/篇/集/幕.
- +3 for exact special headings such as 序章、楔子、番外、后记、尾声、终章.
- +2 for blank line before and +1 for blank line after.
- +2 for sequence continuity with surrounding numeric chapters.
- -4 for punctuation that makes the line sentence-like.
- -4 for lines over 80 Unicode scalar values.
- Require score >= 4 for chapters and >= 5 for volume headings.

Represent offsets against the normalized UTF-8 text, not the original legacy byte stream. Preserve preface metadata before the first accepted chapter.

- [ ] **Step 5: Implement transactional TXT preview/import**

TxtNovelImporter.preview reads bytes, decodes them, computes SHA-256, parses metadata/chapters and returns ImportedNovelPreview without writing the library. importPreview writes normalized content and index.json under a temporary application-support directory, then renames it to novels/local/{sha256}.

- [ ] **Step 6: Run focused tests**

~~~powershell
flutter test test/novel_encoding_test.dart test/txt_chapter_parser_test.dart test/txt_novel_importer_test.dart
dart analyze lib/core/novel/import
~~~

Expected: PASS.

- [ ] **Step 7: Commit**

~~~powershell
git add pubspec.yaml pubspec.lock lib/core/novel/import test/novel_encoding_test.dart test/txt_chapter_parser_test.dart test/txt_novel_importer_test.dart
git commit -m "feat: import and index TXT novels"
~~~

## Task 5: Safe EPUB 2 and EPUB 3 Import

**Files:**
- Modify: pubspec.yaml
- Create: lib/core/novel/import/epub_preflight.dart
- Create: lib/core/novel/import/epub_novel_importer.dart
- Create: test/epub_preflight_test.dart
- Create: test/epub_novel_importer_test.dart

- [ ] **Step 1: Add EPUB dependency**

~~~yaml
  epubx: ^4.0.0
~~~

Run flutter pub get. Keep the existing archive dependency because preflight must inspect ZIP metadata before epubx reads book content.

- [ ] **Step 2: Write failing ZIP safety tests**

Build archives in memory with archive package and assert:

~~~dart
test('rejects traversal and absolute EPUB entries', () {
  expect(
    () => EpubPreflight.validate(entries(['../escape.xhtml'])),
    throwsFormatException,
  );
  expect(
    () => EpubPreflight.validate(entries(['/root.xhtml'])),
    throwsFormatException,
  );
});

test('rejects excessive totals and compression ratio', () {
  expect(
    () => EpubPreflight.validate(
      entries(['OEBPS/a.xhtml'], size: 129 * 1024 * 1024),
    ),
    throwsFormatException,
  );
});
~~~

Limits: 20,000 entries, 128 MiB per entry, 1 GiB total uncompressed size, and ratio 200:1 for entries over 1 MiB. Normalize with posix rules and verify the resolved path stays below the import root.

- [ ] **Step 3: Write EPUB 2/3 parser tests**

Create small synthetic in-memory fixtures:

- EPUB 2: mimetype, container.xml, content.opf, toc.ncx, two XHTML spine items, cover and ruby.
- EPUB 3: nav.xhtml instead of NCX.
- Broken EPUB: OPF without spine.

~~~dart
test('EPUB 2 follows spine and NCX instead of filename order', () async {
  final preview = await importer.preview(epub2Fixture());
  expect(preview.title, '测试 EPUB 2');
  expect(preview.chapters.map((e) => e.title), ['序章', '第一章']);
  expect(preview.hasCover, true);
});

test('EPUB 3 reads nav document and keeps ruby markup', () async {
  final book = await importer.importBytes(epub3Fixture());
  final html = await book.readChapter('c1');
  expect(html, contains('<ruby>'));
});
~~~

- [ ] **Step 4: Implement preflight and importer**

EpubNovelImporter:

1. Copies the original EPUB to a temporary private directory.
2. Runs EpubPreflight before reading content.
3. Calls EpubReader.readBook off the UI isolate.
4. Extracts title, authors, language, cover, spine and NCX/NAV labels.
5. Writes sanitized source XHTML and safe resources under deterministic relative paths.
6. Writes index.json with schema 1 and chapter-to-resource mappings.
7. Atomically renames the directory to novels/local/{sha256}.

Reject fixed-layout metadata and empty readable spine. Preserve ruby, images and font resources; do not execute book scripts.

- [ ] **Step 5: Run focused tests**

~~~powershell
flutter test test/epub_preflight_test.dart test/epub_novel_importer_test.dart
dart analyze lib/core/novel/import
~~~

Expected: PASS.

- [ ] **Step 6: Commit**

~~~powershell
git add pubspec.yaml pubspec.lock lib/core/novel/import/epub_preflight.dart lib/core/novel/import/epub_novel_importer.dart test/epub_preflight_test.dart test/epub_novel_importer_test.dart
git commit -m "feat: safely import EPUB novels"
~~~

## Task 6: Novel Library Store and App Scope

**Files:**
- Create: lib/app/novel_library_store.dart
- Modify: lib/app/app.dart
- Create: test/novel_library_store_test.dart

- [ ] **Step 1: Write failing persistence tests**

~~~dart
test('local and remote entries persist in an independent namespace', () async {
  SharedPreferences.setMockInitialValues({});
  final store = NovelLibraryStore();
  await store.load();
  store.addLocal(localEntry('abc'));
  store.toggleRemoteFavorite(remoteEntry('s', 'n'));
  store.saveProgress(
    'remote:s:n',
    const NovelLocator(chapterId: 'c1', blockId: 'p2', fraction: .4),
  );
  final restored = NovelLibraryStore();
  await restored.load();
  expect(restored.entries.length, 2);
  expect(restored.progressFor('remote:s:n')?.blockId, 'p2');
});

test('sync export strips local file paths but keeps fingerprint', () async {
  final data = store.exportData(includeLocalPaths: false);
  expect(data.toString(), isNot(contains('D:\\\\Books')));
  expect(data.toString(), contains('abc'));
});
~~~

- [ ] **Step 2: Implement store models and schema**

Use SharedPreferences keys novel.library.v1, novel.history.v1 and novel.settings.v1. Keys are NovelIdentity.key. Persist progress with a 600 ms debounce. Reader settings include:

~~~dart
enum NovelReaderMode { paged, scroll }
enum NovelReaderTheme { dark, black, white, sepia }

class NovelReaderPreferences {
  const NovelReaderPreferences({
    this.mode = NovelReaderMode.paged,
    this.fontFamily = '',
    this.fontSize = 18,
    this.lineHeight = 1.65,
    this.paragraphSpacing = 10,
    this.horizontalMargin = 22,
    this.theme = NovelReaderTheme.sepia,
    this.keepScreenOn = true,
  });
}
~~~

Local availability is recomputed from the private path on load. Missing files remain visible and recoverable.

- [ ] **Step 3: Add NovelLibraryScope**

Create the store in App, load it before automatic sync, place NovelLibraryScope beside LibraryScope, include its preferences in the root AnimatedBuilder and dispose it at shutdown.

- [ ] **Step 4: Run tests**

~~~powershell
flutter test test/novel_library_store_test.dart test/widget_test.dart
dart analyze lib/app/novel_library_store.dart lib/app/app.dart
~~~

Expected: PASS.

- [ ] **Step 5: Commit**

~~~powershell
git add lib/app/novel_library_store.dart lib/app/app.dart test/novel_library_store_test.dart
git commit -m "feat: persist a separate novel library"
~~~

## Task 7: Safe Document Sanitizer and Offline Document Cache

**Files:**
- Create: lib/core/novel/novel_document_sanitizer.dart
- Create: lib/core/novel/novel_document_cache.dart
- Create: test/novel_document_sanitizer_test.dart
- Create: test/novel_document_cache_test.dart

- [ ] **Step 1: Write failing sanitizer tests**

~~~dart
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
});

test('drops javascript, data HTML and external iframe URLs', () {
  final html = NovelDocumentSanitizer.sanitize(
    '<a href="javascript:x()">x</a><iframe src="https://bad"></iframe>',
  );
  expect(html, isNot(contains('javascript:')));
  expect(html, isNot(contains('iframe')));
});
~~~

- [ ] **Step 2: Implement an allowlist DOM transform**

Parse with package:html. Allow semantic text elements, ruby/rt/rp, img, safe a[href], br, hr and basic tables/lists. Remove script, style, iframe, object, embed, form, input, event attributes and unknown URL schemes. Resolve relative image/anchor URLs against baseUrl. Add stable data-dmr-block IDs to headings and paragraphs.

- [ ] **Step 3: Write cache tests**

~~~dart
test('cache commits only complete documents', () async {
  final cache = NovelDocumentCache(root: temp.path, dio: fakeDio);
  await cache.save('s', 'n', 'c', documentWithTwoImages);
  expect(await cache.read('s', 'n', 'c'), isNotNull);
  expect(Directory(temp.path).listSync(recursive: true), isNotEmpty);
});

test('failed resource download does not publish completed index', () async {
  final cache = NovelDocumentCache(root: temp.path, dio: failingDio);
  await expectLater(cache.save('s', 'n', 'c', document), throwsException);
  expect(await cache.read('s', 'n', 'c'), isNull);
});
~~~

- [ ] **Step 4: Implement transactional cache**

Store document.html, metadata.json and resources below novels/downloads/{source}/{novel}/{chapter}. Download images with the document/source headers, rewrite HTML to local relative paths, then rename the .partial directory. Cache APIs never expose partial data.

- [ ] **Step 5: Run tests and commit**

~~~powershell
flutter test test/novel_document_sanitizer_test.dart test/novel_document_cache_test.dart
dart analyze lib/core/novel/novel_document_sanitizer.dart lib/core/novel/novel_document_cache.dart
git add lib/core/novel/novel_document_sanitizer.dart lib/core/novel/novel_document_cache.dart test/novel_document_sanitizer_test.dart test/novel_document_cache_test.dart
git commit -m "feat: sanitize and cache novel documents"
~~~

## Task 8: Reflowable Novel Document View and Reader

**Files:**
- Create: lib/features/novel/novel_document_view.dart
- Create: lib/features/novel/novel_reader_page.dart
- Create: lib/features/novel/novel_reader_settings_sheet.dart
- Create: test/novel_reader_test.dart

- [ ] **Step 1: Write failing reader widget tests**

Inject a NovelDocumentController fake rather than creating a native WebView in widget tests.

~~~dart
testWidgets('mode and typography changes preserve locator', (tester) async {
  final controller = FakeNovelDocumentController(
    locator: const NovelLocator(
      chapterId: 'c1',
      blockId: 'p7',
      fraction: .3,
    ),
  );
  await tester.pumpWidget(readerHarness(controller));
  await tester.tap(find.byKey(const Key('novel-reader-settings')));
  await tester.tap(find.text('连续滚动'));
  await tester.pumpAndSettle();
  expect(controller.lastRestored?.blockId, 'p7');
});

testWidgets('directory selection loads the selected chapter', (tester) async {
  final controller = FakeNovelDocumentController();
  await tester.pumpWidget(readerHarness(controller));
  await tester.tap(find.byKey(const Key('novel-reader-directory')));
  await tester.tap(find.text('第二章'));
  await tester.pumpAndSettle();
  expect(controller.loadedChapterId, 'c2');
});
~~~

- [ ] **Step 2: Implement the document bridge**

NovelDocumentView uses InAppWebView with book scripts removed. App-owned JavaScript:

- Reports first visible data-dmr-block and fractional offset.
- Restores a locator after layout.
- In paged mode sets column-width to viewport width and reports column count/index.
- In scroll mode reports scroll extent and position.
- Handles safe internal anchors through the App bridge.

Create a strict CSP that allows only local document/image/font data and disables network/script execution except the injected bridge.

- [ ] **Step 3: Implement reader controls**

NovelReaderPage owns chapter navigation, control visibility and persistence. Reuse ReaderKeys for Android volume buttons and wakelock_plus. Add keyboard left/right/PageUp/PageDown on desktop. In paged mode use click zones and horizontal swipes; in scroll mode preserve natural vertical scrolling.

- [ ] **Step 4: Implement settings sheet**

Use segmented controls for paged/scroll, select menus for font/theme, sliders for font size, line height, paragraph spacing and margins, and a toggle for screen-on. Every change captures the locator, applies CSS and restores the locator after layout.

- [ ] **Step 5: Run tests**

~~~powershell
flutter test test/novel_reader_test.dart
dart analyze lib/features/novel/novel_document_view.dart lib/features/novel/novel_reader_page.dart lib/features/novel/novel_reader_settings_sheet.dart
~~~

Expected: PASS.

- [ ] **Step 6: Commit**

~~~powershell
git add lib/features/novel/novel_document_view.dart lib/features/novel/novel_reader_page.dart lib/features/novel/novel_reader_settings_sheet.dart test/novel_reader_test.dart
git commit -m "feat: add reflowable novel reader"
~~~

## Task 9: Novel Download Store

**Files:**
- Create: lib/app/novel_download_store.dart
- Modify: lib/app/app.dart
- Create: test/novel_download_store_test.dart

- [ ] **Step 1: Write failing queue tests**

~~~dart
test('download stores a complete offline chapter and survives reload', () async {
  final store = NovelDownloadStore(
    rootProvider: () async => temp.path,
    sourceBuilder: (_) => fakeSource,
    cacheFactory: cacheFactory,
  );
  await store.load();
  store.enqueue(meta, novel, chapter);
  await store.idle;
  expect(store.isDownloaded('s', 'n', 'c1'), true);
  expect(store.localDocument('s', 'n', 'c1'), isNotNull);
});

test('failed chapter is retryable and never marked complete', () async {
  fakeSource.error = Exception('network');
  store.enqueue(meta, novel, chapter);
  await store.idle;
  expect(store.isDownloaded('s', 'n', 'c1'), false);
  expect(store.failureOf('s', 'n', 'c1'), isNotNull);
});
~~~

- [ ] **Step 2: Implement download records and queue**

DownloadedNovelChapter stores source/novel/chapter metadata, document directory, resource count, byte count and completion time. Jobs call buildNovelSource, sanitize the result, persist through NovelDocumentCache and dispose the source. Expose progress, failure, retry, deleteChapter and deleteNovel.

- [ ] **Step 3: Add NovelDownloadScope**

Create/load/dispose the store in App next to DownloadStore. Do not merge its SharedPreferences index or filesystem root with manga downloads.

- [ ] **Step 4: Run tests and commit**

~~~powershell
flutter test test/novel_download_store_test.dart test/widget_test.dart
dart analyze lib/app/novel_download_store.dart lib/app/app.dart
git add lib/app/novel_download_store.dart lib/app/app.dart test/novel_download_store_test.dart
git commit -m "feat: download novel chapters for offline reading"
~~~

## Task 10: Novel Detail, Directory and Manual Source Switching

**Files:**
- Create: lib/features/novel/novel_detail_page.dart
- Create: lib/features/novel/novel_source_sheet.dart
- Create: lib/features/novel/novel_cover.dart
- Create: test/novel_detail_test.dart

- [ ] **Step 1: Write failing detail tests**

~~~dart
testWidgets('detail uses one source and never merges chapter lists',
    (tester) async {
  final sources = FakeNovelSources({
    'a': chapters('A1', 'A2'),
    'b': chapters('B1'),
  });
  await tester.pumpWidget(detailHarness(sourceId: 'a', sources: sources));
  await tester.pumpAndSettle();
  expect(find.text('A1'), findsOneWidget);
  expect(find.text('B1'), findsNothing);
});

testWidgets('manual source switch replaces the directory', (tester) async {
  await tester.tap(find.byKey(const Key('novel-change-source')));
  await tester.tap(find.text('来源 B'));
  await tester.pumpAndSettle();
  expect(find.text('B1'), findsOneWidget);
  expect(find.text('A1'), findsNothing);
});
~~~

- [ ] **Step 2: Implement detail loading**

Load selected-source detail and chapters independently. Group chapters by volumeId while preserving source order. Show cover, title, authors, status, genres, description, favorite, browser link, download status and chapter list. Opening a chapter prefers NovelDownloadStore local data, then fetches/sanitizes online data.

- [ ] **Step 3: Implement source sheet**

Search enabled novel sources by normalized title. Show matching source name and title; switching replaces sourceId/novelId and reloads the full directory. Never combine chapters from two sources.

- [ ] **Step 4: Implement cover fallbacks**

NovelCover supports remote images with source headers, private EPUB cover files and deterministic TXT covers based on title hash. Generated covers use restrained theme colors and fit long titles without changing layout dimensions.

- [ ] **Step 5: Run tests and commit**

~~~powershell
flutter test test/novel_detail_test.dart
dart analyze lib/features/novel/novel_detail_page.dart lib/features/novel/novel_source_sheet.dart lib/features/novel/novel_cover.dart
git add lib/features/novel/novel_detail_page.dart lib/features/novel/novel_source_sheet.dart lib/features/novel/novel_cover.dart test/novel_detail_test.dart
git commit -m "feat: add novel details and source switching"
~~~

## Task 11: Novel Browser and Discovery Integration

**Files:**
- Create: lib/features/novel/novel_browser.dart
- Modify: lib/features/discovery/discovery_page.dart
- Modify: lib/app/content_kind.dart
- Create: test/novel_browser_test.dart
- Modify: test/widget_test.dart

- [ ] **Step 1: Write failing mixed-search tests**

~~~dart
testWidgets('mixed novel search isolates failures and deduplicates titles',
    (tester) async {
  final sources = FakeNovelSources({
    'a': [novel('诡秘之主')],
    'b': [novel('詭秘之主')],
    'broken': Exception('timeout'),
  });
  await tester.pumpWidget(browserHarness(sources));
  await tester.enterText(find.byType(TextField), '诡秘');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
  expect(find.text('诡秘之主'), findsOneWidget);
  expect(find.textContaining('2 个来源'), findsOneWidget);
});
~~~

- [ ] **Step 2: Implement NovelBrowser**

Adapt the proven AnimeBrowser boundary rather than adding more state to DiscoveryPage. NovelBrowser owns query, pagination, filters, current source, mixed cursors, translation fallback, dedup keys and partial errors. Use SourceController.currentFor('novel') and showSourcePicker(kind: 'novel').

- [ ] **Step 3: Enable ContentKind.novel**

DiscoveryPage keeps the existing top kind switch and renders NovelBrowser for the novel branch. The shared top search field forwards the query to NovelBrowser through a GlobalKey, matching the current anime integration. Switching kind clears only visible query state and does not resume manga pagination with a novel query.

- [ ] **Step 4: Run tests**

~~~powershell
flutter test test/novel_browser_test.dart test/widget_test.dart test/search_rank_test.dart
dart analyze lib/features/novel/novel_browser.dart lib/features/discovery/discovery_page.dart lib/app/content_kind.dart
~~~

Expected: PASS.

- [ ] **Step 5: Commit**

~~~powershell
git add lib/features/novel/novel_browser.dart lib/features/discovery/discovery_page.dart lib/app/content_kind.dart test/novel_browser_test.dart test/widget_test.dart
git commit -m "feat: enable novel discovery and search"
~~~

## Task 12: Local Import Flow and Separate Novel Shelf

**Files:**
- Create: lib/features/novel/novel_import_sheet.dart
- Create: lib/features/novel/novel_library_view.dart
- Modify: lib/features/library/library_page.dart
- Modify: lib/features/library/history_page.dart
- Create: test/novel_import_sheet_test.dart
- Create: test/novel_library_view_test.dart

- [ ] **Step 1: Write failing import UI tests**

~~~dart
testWidgets('TXT preview allows encoding retry before commit', (tester) async {
  final importer = FakeTxtImporter(
    preview: preview(encoding: 'gb18030', chapters: 1210),
  );
  await tester.pumpWidget(importHarness(importer));
  await tester.tap(find.text('导入本地小说'));
  await tester.pumpAndSettle();
  expect(find.text('GB18030 / GBK'), findsOneWidget);
  expect(find.text('1210 章'), findsOneWidget);
  await tester.tap(find.text('Big5'));
  expect(importer.lastForcedEncoding, 'big5');
});

testWidgets('cancelled import creates no library entry', (tester) async {
  await tester.tap(find.text('取消'));
  expect(NovelLibraryScope.read(lastContext).entries, isEmpty);
});
~~~

- [ ] **Step 2: Implement file selection and preview**

Use file_picker with allowedExtensions txt and epub. TXT preview exposes encoding selection; both previews allow editing title/author before confirmation. Run parsing asynchronously, show determinate progress where available and provide cancel. Only confirmed successful imports call NovelLibraryStore.addLocal.

- [ ] **Step 3: Write shelf separation tests**

~~~dart
testWidgets('library switches between manga and novel without mixing cards',
    (tester) async {
  await tester.pumpWidget(libraryHarness(
    mangaTitle: '漫画甲',
    novelTitle: '小说乙',
  ));
  expect(find.text('漫画甲'), findsOneWidget);
  expect(find.text('小说乙'), findsNothing);
  await tester.tap(find.text('小说'));
  await tester.pumpAndSettle();
  expect(find.text('小说乙'), findsOneWidget);
  expect(find.text('漫画甲'), findsNothing);
});
~~~

- [ ] **Step 4: Implement NovelLibraryView**

LibraryPage owns only the manga/novel segmented selection and delegates the novel body. NovelLibraryView provides local import, continue reading, favorites, missing-file recovery, search and novel history. Reimport matches SHA-256 and reattaches the private path without replacing the saved locator.

- [ ] **Step 5: Implement safe deletion**

Deleting a local novel requires a dialog that states the App private copy will be removed. Delete the directory only after exact-path validation confirms it is below the novel storage root. Remote unfavorite never deletes downloads automatically.

- [ ] **Step 6: Run tests and commit**

~~~powershell
flutter test test/novel_import_sheet_test.dart test/novel_library_view_test.dart test/widget_test.dart
dart analyze lib/features/novel/novel_import_sheet.dart lib/features/novel/novel_library_view.dart lib/features/library
git add lib/features/novel/novel_import_sheet.dart lib/features/novel/novel_library_view.dart lib/features/library test/novel_import_sheet_test.dart test/novel_library_view_test.dart
git commit -m "feat: add local novel shelf and import flow"
~~~

## Task 13: Separate Novel Downloads UI

**Files:**
- Create: lib/features/novel/novel_downloads_view.dart
- Modify: lib/features/downloads/downloads_page.dart
- Create: test/novel_downloads_view_test.dart

- [ ] **Step 1: Write failing download-tab tests**

~~~dart
testWidgets('download page separates manga and novel records',
    (tester) async {
  await tester.pumpWidget(downloadHarness(
    mangaTitle: '漫画下载',
    novelTitle: '小说下载',
  ));
  expect(find.text('漫画下载'), findsOneWidget);
  expect(find.text('小说下载'), findsNothing);
  await tester.tap(find.text('小说'));
  await tester.pumpAndSettle();
  expect(find.text('小说下载'), findsOneWidget);
});
~~~

- [ ] **Step 2: Implement NovelDownloadsView**

Group records by sourceId/novelId, show active jobs, chapter count, byte size, failures and retry. Opening a group routes to NovelDetailPage when the source exists; if the source is gone, open downloaded chapters through an offline-only detail model.

- [ ] **Step 3: Add the page-level segmented switch**

DownloadsPage delegates the existing manga body and the new novel body. Keep navigation dimensions stable on phone and desktop; do not nest either page body in a decorative card.

- [ ] **Step 4: Run tests and commit**

~~~powershell
flutter test test/novel_downloads_view_test.dart
dart analyze lib/features/novel/novel_downloads_view.dart lib/features/downloads/downloads_page.dart
git add lib/features/novel/novel_downloads_view.dart lib/features/downloads/downloads_page.dart test/novel_downloads_view_test.dart
git commit -m "feat: separate novel offline downloads"
~~~

## Task 14: Backup, Cloud Sync, Localization and Acceptance

**Files:**
- Modify: lib/app/backup.dart
- Modify: lib/core/sync/sync_data.dart
- Modify: lib/core/sync/sync_controller.dart
- Modify: lib/features/settings/sync_page.dart
- Modify: lib/features/settings/settings_page.dart
- Modify: lib/l10n/app_zh.arb
- Modify: lib/l10n/app_zh_Hant.arb
- Modify: lib/l10n/app_en.arb
- Modify: lib/l10n/app_ja.arb
- Modify: README.md
- Create: test/novel_sync_test.dart
- Create: test/novel_backup_test.dart
- Modify: test/l10n_test.dart

- [ ] **Step 1: Write failing backup/sync tests**

~~~dart
test('backup contains novel metadata and progress but no book bytes or path',
    () async {
  final data = buildBackup(mangaStore, novelStoreWithLocalBook);
  final encoded = jsonEncode(data);
  expect(encoded, contains('novels'));
  expect(encoded, contains('local:abc'));
  expect(encoded, isNot(contains('original.epub')));
  expect(encoded, isNot(contains('D:\\\\')));
});

test('novel history merges by updated time and keeps local fingerprint', () {
  final merged = SyncData.merge(localNovelBlob, remoteNovelBlob);
  final novel = merged['novels']['history']['local:abc'];
  expect(novel['u'], remoteUpdatedAt);
  expect(novel['fingerprint'], 'abc');
});
~~~

- [ ] **Step 2: Extend backup without changing the existing file format**

Change exportBackup/importBackup to accept LibraryStore and NovelLibraryStore. Keep every existing manga export key at the JSON root and append one top-level novels object with schema 1; do not wrap the old data in a new library object. Import passes the root to LibraryStore.importData and passes root['novels'] to NovelLibraryStore only when that map exists. This makes old backups load as an empty novel library and lets old App versions ignore novels without clearing manga data. Exclude private file paths and all content bytes.

- [ ] **Step 3: Extend SyncData and SyncController**

Pass NovelLibraryStore through build/apply and controller entrypoints. Favorites/history categories include corresponding novel metadata and locators. readerSettings includes novel typography. novelSources remains its own source category from Task 3. Merge:

- Remote novel favorites by stable identity and newest addedAt.
- Progress by newest updatedAt.
- Local fingerprints and metadata, never paths.
- Settings by existing last-write-wins timestamp.

Update App and SyncPage call sites together so every signature compiles in one commit.

- [ ] **Step 4: Complete all four locales**

Add every novel label, import state, encoding name, format error, shelf/download state, reader setting and recovery message to Simplified Chinese, Traditional Chinese, English and Japanese ARB files. Run flutter gen-l10n and update l10n tests so key parity is enforced.

- [ ] **Step 5: Update README**

Document:

- Source manifest kind: novel.
- Novel prepare/handle contract.
- TXT/EPUB local import support.
- DRM/fixed-layout limitations.
- The fact that local book files are never uploaded.
- Windows and Android parity.

- [ ] **Step 6: Run all automated checks**

~~~powershell
flutter pub get
flutter gen-l10n
flutter analyze
flutter test --reporter compact
flutter build windows
flutter build apk --debug
~~~

Expected: analysis has no findings, all tests pass, Windows build succeeds and Android debug APK succeeds.

- [ ] **Step 7: Run local sample acceptance without adding files to Git**

Use:

- 雪中悍刀行.txt
- 我有一座恐怖屋.txt
- 诡秘之主.txt
- 刀剑神域 进击篇09.epub

Verify:

- All three TXT files decode as GB18030/GBK and import without UI blocking.
- Chapter counts are plausible and false prose headings do not split chapters.
- EPUB 2 NCX order, 25 spine documents, images and ruby render.
- Switch paged/scroll and change typography without losing the paragraph.
- Restart restores local books and progress.
- Deleting/moving the external QQ files does not break private imported copies.
- Offline downloaded online chapters open with networking disabled.

Record observed counts, build commands and remaining real-device limitations in docs/release/小说板块验收记录.md. Do not copy copyrighted sample text into the record.

- [ ] **Step 8: Check Git safety and commit**

~~~powershell
git status --short
git diff --check
git ls-files .tools ReleaseOutput android/build
git ls-files | Select-String -Pattern '雪中悍刀行|我有一座恐怖屋|诡秘之主|刀剑神域'
~~~

Expected: generated directories and sample books are not tracked.

~~~powershell
git add lib test pubspec.yaml pubspec.lock README.md docs/release/小说板块验收记录.md
git commit -m "docs: verify novel reader support"
~~~

## Final Review Checklist

- [ ] Every new production behavior was introduced by a failing focused test.
- [ ] Existing manga and anime model signatures remain compatible.
- [ ] Novel sources are external and filtered by kind: novel.
- [ ] Different-source novel chapter lists are never merged automatically.
- [ ] TXT import supports BOM, UTF-8, UTF-16, GB18030/GBK and manual Big5.
- [ ] EPUB 2 NCX, EPUB 3 NAV, spine, images, ruby and font fallback work.
- [ ] Book-provided scripts and unsafe ZIP paths cannot execute or escape storage.
- [ ] Paged/scroll switching restores the same paragraph locator.
- [ ] Novel shelf/history/downloads do not mix with manga.
- [ ] Cloud sync and JSON backup contain metadata/progress only.
- [ ] Local samples and generated build output remain untracked.
- [ ] Windows and Android builds are verified, with unavailable real-device checks documented.
