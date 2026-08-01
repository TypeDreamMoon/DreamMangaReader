import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:epub_plus/epub_plus.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'epub_preflight.dart';

typedef EpubApplicationSupportDirectory = Future<Directory> Function();

class EpubNovelImportPreview extends ImportedNovelPreview {
  EpubNovelImportPreview({
    required super.sha256,
    required super.title,
    required super.authors,
    required super.chapters,
    required super.hasCover,
    required this.language,
    required List<int> originalBytes,
    required Map<String, List<int>> resources,
    required Map<String, String> chapterResources,
  })  : originalBytes = List<int>.unmodifiable(originalBytes),
        resources = Map<String, List<int>>.unmodifiable(resources.map(
          (path, bytes) => MapEntry(path, List<int>.unmodifiable(bytes)),
        )),
        chapterResources = Map.unmodifiable(chapterResources),
        super(origin: NovelOrigin.localEpub);

  final String? language;
  final List<int> originalBytes;
  final Map<String, List<int>> resources;
  final Map<String, String> chapterResources;
}

class ImportedEpubNovel {
  const ImportedEpubNovel({
    required this.directory,
    required this.preview,
  });

  final Directory directory;
  final EpubNovelImportPreview preview;

  Future<String> readChapter(String chapterId) async {
    final relativePath = preview.chapterResources[chapterId];
    if (relativePath == null) {
      throw ArgumentError.value(chapterId, 'chapterId', 'unknown chapter');
    }
    final file = File(_safeChild(
      Directory(_join(directory.path, 'resources')),
      relativePath,
    ));
    return file.readAsString(encoding: utf8);
  }
}

class EpubNovelImporter {
  EpubNovelImporter({
    EpubApplicationSupportDirectory? applicationSupportDirectory,
  }) : _applicationSupportDirectory =
            applicationSupportDirectory ?? getApplicationSupportDirectory;

  final EpubApplicationSupportDirectory _applicationSupportDirectory;

  Future<EpubNovelImportPreview> preview(File source) async {
    return previewBytes(await source.readAsBytes());
  }

  Future<EpubNovelImportPreview> previewBytes(List<int> input) async {
    final bytes = Uint8List.fromList(input);
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      EpubPreflight.validate(archive.files);
    } catch (error) {
      if (error is FormatException) rethrow;
      throw FormatException('Invalid EPUB archive: $error');
    }

    final EpubBook book;
    try {
      book = await Isolate.run(() => _readBookCompat(bytes));
    } catch (error) {
      throw FormatException('EPUB could not be parsed: $error');
    }
    final package = book.schema?.package;
    final contentDirectory = book.schema?.contentDirectoryPath ?? '';
    final metadata = package?.metadata;
    final manifest = package?.manifest;
    final spine = package?.spine;
    if (package == null ||
        metadata == null ||
        manifest == null ||
        spine == null) {
      throw const FormatException('EPUB is missing its package spine');
    }
    if (_isFixedLayout(metadata)) {
      throw const FormatException('Fixed-layout EPUB is not supported');
    }

    final manifestById = <String, EpubManifestItem>{};
    final manifestPaths = <String>{};
    for (final item in manifest.items) {
      final id = item.id;
      final href = item.href;
      if (id != null && id.isNotEmpty) manifestById[id] = item;
      if (href != null && href.isNotEmpty) {
        final path = _manifestRelativePath(contentDirectory, href);
        if (!manifestPaths.add(path)) {
          throw FormatException('EPUB manifest contains duplicate path: $path');
        }
      }
    }

    final labels = _chapterLabels(book.chapters, contentDirectory);
    final content = book.content;
    if (content == null) {
      throw const FormatException('EPUB has no readable content');
    }
    final resources = <String, Uint8List>{};
    for (final entry in content.allFiles.entries) {
      final path = _manifestRelativePath(contentDirectory, entry.key);
      final file = entry.value;
      if (file is EpubTextContentFile) {
        final value = file.content;
        if (value == null) continue;
        final text = file.contentMimeType == 'application/xhtml+xml'
            ? _sanitizeXhtml(value)
            : value;
        resources[path] = Uint8List.fromList(utf8.encode(text));
      } else if (file is EpubByteContentFile && file.content != null) {
        resources[path] = Uint8List.fromList(file.content!);
      }
    }

    final chapters = <NovelChapter>[];
    final chapterResources = <String, String>{};
    for (final itemRef in spine.items) {
      if (!itemRef.isLinear) continue;
      final item = manifestById[itemRef.idRef];
      if (item == null || item.href == null) continue;
      if (item.mediaType != 'application/xhtml+xml' &&
          item.mediaType != 'text/html') {
        continue;
      }
      final resourcePath = _manifestRelativePath(contentDirectory, item.href!);
      if (!resources.containsKey(resourcePath)) continue;
      final label = labels[resourcePath];
      final id = 'c${chapters.length + 1}';
      chapters.add(NovelChapter(
        id: id,
        title: label?.title ?? _fallbackChapterTitle(resourcePath, resources),
        number: (chapters.length + 1).toDouble(),
        epubAnchor: label?.anchor,
      ));
      chapterResources[id] = resourcePath;
    }
    if (chapters.isEmpty) {
      throw const FormatException('EPUB has an empty readable spine');
    }

    final title = (book.title ?? '').trim();
    final authors = book.authors
        .whereType<String>()
        .map((author) => author.trim())
        .where((author) => author.isNotEmpty)
        .toList(growable: false);
    final hasCover = _hasCover(book, manifest, metadata);

    return EpubNovelImportPreview(
      sha256: sha256.convert(bytes).toString(),
      title: title.isEmpty ? '未命名 EPUB' : title,
      authors: List.unmodifiable(authors),
      chapters: List.unmodifiable(chapters),
      hasCover: hasCover,
      language: metadata.languages.isEmpty ? null : metadata.languages.first,
      originalBytes: bytes,
      resources: resources,
      chapterResources: chapterResources,
    );
  }

  Future<ImportedEpubNovel> importBytes(List<int> bytes) async {
    return importPreview(await previewBytes(bytes));
  }

  Future<ImportedEpubNovel> importPreview(
    EpubNovelImportPreview preview,
  ) async {
    final support = await _applicationSupportDirectory();
    final novels = Directory(_join(support.path, 'novels'));
    final local = Directory(_join(novels.path, 'local'));
    await local.create(recursive: true);

    final destination = Directory(_join(local.path, preview.sha256));
    if (await destination.exists()) {
      return ImportedEpubNovel(directory: destination, preview: preview);
    }

    final temporary = Directory(_join(
      novels.path,
      '.tmp-${preview.sha256}-$pid-${DateTime.now().microsecondsSinceEpoch}',
    ));
    await temporary.create();
    try {
      await File(_join(temporary.path, 'original.epub')).writeAsBytes(
        preview.originalBytes,
        flush: true,
      );
      final resourcesDirectory = Directory(_join(temporary.path, 'resources'));
      await resourcesDirectory.create();
      for (final resource in preview.resources.entries) {
        final file = File(_safeChild(resourcesDirectory, resource.key));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(resource.value, flush: true);
      }
      await File(_join(temporary.path, 'index.json')).writeAsString(
        jsonEncode(_buildIndex(preview)),
        encoding: utf8,
        flush: true,
      );
      if (await destination.exists()) {
        await temporary.delete(recursive: true);
        return ImportedEpubNovel(directory: destination, preview: preview);
      }
      final installed = await temporary.rename(destination.path);
      return ImportedEpubNovel(directory: installed, preview: preview);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete(recursive: true);
      if (await destination.exists()) {
        return ImportedEpubNovel(directory: destination, preview: preview);
      }
      rethrow;
    }
  }
}

Future<EpubBook> _readBookCompat(Uint8List bytes) async {
  try {
    return await EpubReader.readBook(bytes);
  } catch (error) {
    final reference = await EpubReader.openBook(bytes);
    final package = reference.schema?.package;
    if (package == null || !_coverMetadataUsesHref(package)) rethrow;
    final contentRef = reference.content;
    if (contentRef == null) rethrow;
    return EpubBook(
      title: reference.title,
      author: reference.author,
      authors: reference.authors,
      schema: reference.schema,
      content: await EpubReader.readContent(contentRef),
      chapters: await EpubReader.readChapters(reference.getChapters()),
    );
  }
}

bool _coverMetadataUsesHref(EpubPackage package) {
  final metadata = package.metadata;
  final manifest = package.manifest;
  if (metadata == null || manifest == null) return false;
  for (final meta in metadata.metaItems) {
    if ((meta.name ?? '').toLowerCase() != 'cover') continue;
    final reference = meta.content;
    if (reference == null || reference.isEmpty) return false;
    final item = _findCoverManifestItem(reference, manifest);
    return item != null && item.id != reference;
  }
  return false;
}

bool _hasCover(
  EpubBook book,
  EpubManifest manifest,
  EpubMetadata metadata,
) {
  if (book.coverImage != null ||
      manifest.items.any((item) => (item.properties ?? '')
          .split(RegExp(r'\s+'))
          .contains('cover-image'))) {
    return true;
  }
  for (final meta in metadata.metaItems) {
    if ((meta.name ?? '').toLowerCase() != 'cover') continue;
    final reference = meta.content;
    if (reference == null || reference.isEmpty) continue;
    return _findCoverManifestItem(reference, manifest) != null;
  }
  return false;
}

EpubManifestItem? _findCoverManifestItem(
  String reference,
  EpubManifest manifest,
) {
  for (final item in manifest.items) {
    if (item.id == reference && (item.mediaType ?? '').startsWith('image/')) {
      return item;
    }
  }
  for (final item in manifest.items) {
    if (item.href == reference && (item.mediaType ?? '').startsWith('image/')) {
      return item;
    }
  }
  final basenameMatches = manifest.items.where((item) {
    final href = item.href;
    return href != null &&
        (item.mediaType ?? '').startsWith('image/') &&
        href.replaceAll('\\', '/').split('/').last == reference;
  }).toList(growable: false);
  return basenameMatches.length == 1 ? basenameMatches.single : null;
}

Map<String, Object?> _buildIndex(EpubNovelImportPreview preview) => {
      'schema': 1,
      'sha256': preview.sha256,
      'origin': 'localEpub',
      'title': preview.title,
      'authors': preview.authors,
      'language': preview.language,
      'hasCover': preview.hasCover,
      'chapters': preview.chapters
          .map((chapter) => {
                'id': chapter.id,
                'title': chapter.title,
                'number': chapter.number,
                'resource': preview.chapterResources[chapter.id],
                'anchor': chapter.epubAnchor,
              })
          .toList(growable: false),
    };

bool _isFixedLayout(EpubMetadata metadata) {
  for (final item in metadata.metaItems) {
    final key = (item.property ?? item.name ?? '').trim().toLowerCase();
    final value = (item.content ?? '').trim().toLowerCase();
    if ((key == 'rendition:layout' && value == 'pre-paginated') ||
        (key == 'fixed-layout' && value != 'false' && value != 'no')) {
      return true;
    }
  }
  return metadata.types.any(
    (type) => type.toLowerCase().contains('fixed-layout'),
  );
}

class _ChapterLabel {
  const _ChapterLabel(this.title, this.anchor);

  final String title;
  final String? anchor;
}

Map<String, _ChapterLabel> _chapterLabels(
  List<EpubChapter> chapters,
  String contentDirectory,
) {
  final result = <String, _ChapterLabel>{};
  void collect(List<EpubChapter> values) {
    for (final chapter in values) {
      final fileName = chapter.contentFileName;
      final title = (chapter.title ?? '').trim();
      if (fileName != null && title.isNotEmpty) {
        final path = _manifestRelativePath(contentDirectory, fileName);
        result.putIfAbsent(path, () => _ChapterLabel(title, chapter.anchor));
      }
      collect(chapter.subChapters);
    }
  }

  collect(chapters);
  return result;
}

String _fallbackChapterTitle(
  String resourcePath,
  Map<String, Uint8List> resources,
) {
  final content = resources[resourcePath];
  if (content != null) {
    final document = html_parser.parse(utf8.decode(content));
    final title = document.querySelector('title')?.text.trim();
    if (title != null && title.isNotEmpty) return title;
  }
  final name = resourcePath.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String _manifestRelativePath(String contentDirectory, String href) {
  try {
    final uri = Uri.parse(href);
    if (uri.hasScheme || uri.hasAuthority) {
      throw FormatException('EPUB manifest path must be relative: $href');
    }
    return EpubPreflight.resolveRelativePath(
      contentDirectory,
      Uri.decodeFull(uri.path),
    );
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException('Invalid EPUB manifest path $href: $error');
  }
}

String _sanitizeXhtml(String source) {
  final document = html_parser.parse(source);
  for (final element in document.querySelectorAll(
    'script, iframe, object, embed, meta[http-equiv="refresh"]',
  )) {
    element.remove();
  }
  for (final element in document.querySelectorAll('*')) {
    final removals = <Object>[];
    for (final attribute in element.attributes.entries) {
      final name = attribute.key.toString().toLowerCase();
      final value = attribute.value.trimLeft().toLowerCase();
      if (name.startsWith('on') ||
          ((name == 'href' ||
                  name == 'src' ||
                  name == 'xlink:href' ||
                  name == 'formaction') &&
              value.startsWith('javascript:'))) {
        removals.add(attribute.key);
      }
    }
    for (final name in removals) {
      element.attributes.remove(name);
    }
  }
  return document.outerHtml;
}

String _safeChild(Directory root, String relativePath) {
  final normalized = EpubPreflight.normalizeRelativePath(relativePath);
  var result = root.path;
  for (final part in normalized.split('/')) {
    result = _join(result, part);
  }
  return result;
}

String _join(String parent, String child) {
  if (parent.endsWith(Platform.pathSeparator)) return '$parent$child';
  return '$parent${Platform.pathSeparator}$child';
}
