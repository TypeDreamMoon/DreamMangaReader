enum NovelStatus { unknown, ongoing, completed, hiatus, cancelled }

enum NovelOrigin { remote, localTxt, localEpub }

enum NovelDocumentFormat { text, html }

class NovelIdentity {
  const NovelIdentity._(this.key);

  factory NovelIdentity.remote(String sourceId, String novelId) {
    _requireNotBlank(sourceId, 'sourceId');
    _requireNotBlank(novelId, 'novelId');
    return NovelIdentity._('remote:$sourceId:$novelId');
  }

  factory NovelIdentity.local(String sha256) {
    _requireNotBlank(sha256, 'sha256');
    return NovelIdentity._('local:${sha256.toLowerCase()}');
  }

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

class NovelChapter {
  const NovelChapter({
    required this.id,
    required this.title,
    this.number,
    this.publishedAt,
    this.volumeId,
    this.volumeTitle,
    this.epubAnchor,
  });

  final String id;
  final String title;
  final double? number;
  final int? publishedAt;
  final String? volumeId;
  final String? volumeTitle;
  final String? epubAnchor;
}

class NovelVolume {
  const NovelVolume({
    required this.id,
    required this.title,
    this.chapters = const [],
  });

  final String id;
  final String title;
  final List<NovelChapter> chapters;
}

class NovelDocument {
  NovelDocument({
    required this.format,
    required String content,
    this.baseUrl,
    Map<String, String> resources = const {},
  })  : content = _requireNotBlank(content, 'content'),
        resources = Map.unmodifiable(resources);

  final NovelDocumentFormat format;
  final String content;
  final String? baseUrl;
  final Map<String, String> resources;
}

class NovelLocator {
  const NovelLocator({
    required this.chapterId,
    this.blockId,
    double fraction = 0,
  }) : fraction = fraction != fraction
            ? 0.0
            : fraction < 0
                ? 0.0
                : fraction > 1
                    ? 1.0
                    : fraction;

  final String chapterId;
  final String? blockId;
  final double fraction;
}

class ImportedNovelPreview {
  const ImportedNovelPreview({
    required this.sha256,
    required this.origin,
    required this.title,
    this.authors = const [],
    this.chapters = const [],
    this.hasCover = false,
  });

  final String sha256;
  final NovelOrigin origin;
  final String title;
  final List<String> authors;
  final List<NovelChapter> chapters;
  final bool hasCover;
}

String _requireNotBlank(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return value;
}
