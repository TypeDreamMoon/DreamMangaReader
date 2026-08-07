import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models.dart';
import 'novel_reader_models.dart';

abstract final class NovelReaderTextCaps {
  static const quote = 256;
  static const context = 128;
  static const excerpt = 256;
}

class NovelAnnotationRange {
  const NovelAnnotationRange({
    required this.start,
    required this.end,
    required this.quote,
  });

  factory NovelAnnotationRange.fromSelection(NovelSelection selection) {
    return NovelAnnotationRange(
      start: _portableLocator(selection.start),
      end: _portableLocator(selection.end),
      quote: _cap(selection.text, NovelReaderTextCaps.quote),
    );
  }

  factory NovelAnnotationRange.fromJson(Map<String, dynamic> json) {
    return NovelAnnotationRange(
      start: _portableLocator(
        NovelLocator.fromJson(_map(json['start'], 'start')),
      ),
      end: _portableLocator(
        NovelLocator.fromJson(_map(json['end'], 'end')),
      ),
      quote: _cap(_string(json['quote'], 'quote'), NovelReaderTextCaps.quote),
    );
  }

  final NovelLocator start;
  final NovelLocator end;
  final String quote;

  Map<String, Object?> toJson() => {
        'start': _portableLocator(start).toJson(),
        'end': _portableLocator(end).toJson(),
        'quote': _cap(quote, NovelReaderTextCaps.quote),
      };
}

class NovelBookmark {
  const NovelBookmark({
    required this.id,
    required this.bookKey,
    required this.locator,
    required this.excerpt,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory NovelBookmark.create({
    required String bookKey,
    required NovelLocator locator,
    required String excerpt,
    required int createdAt,
  }) {
    final portable = _portableLocator(locator);
    return NovelBookmark(
      id: _stableId('bookmark', [bookKey, portable.toJson(), createdAt]),
      bookKey: _notBlank(bookKey, 'bookKey'),
      locator: portable,
      excerpt: _cap(excerpt, NovelReaderTextCaps.excerpt),
      createdAt: _timestamp(createdAt, 'createdAt'),
      updatedAt: _timestamp(createdAt, 'createdAt'),
    );
  }

  factory NovelBookmark.fromJson(Map<String, dynamic> json) {
    final createdAt = _integer(json['createdAt'], 'createdAt');
    final updatedAt = _integer(json['updatedAt'], 'updatedAt');
    final deletedAt = _optionalInteger(json['deletedAt'], 'deletedAt');
    return NovelBookmark(
      id: _notBlank(_string(json['id'], 'id'), 'id'),
      bookKey: _notBlank(_string(json['bookKey'], 'bookKey'), 'bookKey'),
      locator: _portableLocator(
        NovelLocator.fromJson(_map(json['locator'], 'locator')),
      ),
      excerpt: _cap(
        _string(json['excerpt'], 'excerpt'),
        NovelReaderTextCaps.excerpt,
      ),
      createdAt: _timestamp(createdAt, 'createdAt'),
      updatedAt: _timestamp(updatedAt, 'updatedAt'),
      deletedAt: deletedAt == null ? null : _timestamp(deletedAt, 'deletedAt'),
    );
  }

  final String id;
  final String bookKey;
  final NovelLocator locator;
  final String excerpt;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;

  bool get isDeleted => deletedAt != null;

  NovelBookmark copyWith({
    NovelLocator? locator,
    String? excerpt,
    int? updatedAt,
    int? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return NovelBookmark(
      id: id,
      bookKey: bookKey,
      locator: _portableLocator(locator ?? this.locator),
      excerpt: _cap(excerpt ?? this.excerpt, NovelReaderTextCaps.excerpt),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
    );
  }

  NovelBookmark deleted(int timestamp) => copyWith(
        updatedAt: timestamp,
        deletedAt: timestamp,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'bookKey': bookKey,
        'locator': _portableLocator(locator).toJson(),
        'excerpt': _cap(excerpt, NovelReaderTextCaps.excerpt),
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (deletedAt != null) 'deletedAt': deletedAt,
      };
}

class NovelAnnotation {
  const NovelAnnotation({
    required this.id,
    required this.bookKey,
    required this.range,
    required this.colorId,
    required this.createdAt,
    required this.updatedAt,
    this.note,
    this.deletedAt,
  });

  factory NovelAnnotation.create({
    required String bookKey,
    required NovelAnnotationRange range,
    required String colorId,
    required int createdAt,
    String? note,
  }) {
    final normalizedBookKey = _notBlank(bookKey, 'bookKey');
    final normalizedColor = _notBlank(colorId, 'colorId');
    return NovelAnnotation(
      id: _stableId(
        'annotation',
        [normalizedBookKey, range.toJson(), createdAt],
      ),
      bookKey: normalizedBookKey,
      range: NovelAnnotationRange.fromJson(range.toJson()),
      colorId: normalizedColor,
      createdAt: _timestamp(createdAt, 'createdAt'),
      updatedAt: _timestamp(createdAt, 'createdAt'),
      note: _optionalText(note),
    );
  }

  factory NovelAnnotation.fromJson(Map<String, dynamic> json) {
    final deletedAt = _optionalInteger(json['deletedAt'], 'deletedAt');
    return NovelAnnotation(
      id: _notBlank(_string(json['id'], 'id'), 'id'),
      bookKey: _notBlank(_string(json['bookKey'], 'bookKey'), 'bookKey'),
      range: NovelAnnotationRange.fromJson(_map(json['range'], 'range')),
      colorId: _notBlank(_string(json['colorId'], 'colorId'), 'colorId'),
      createdAt: _timestamp(
        _integer(json['createdAt'], 'createdAt'),
        'createdAt',
      ),
      updatedAt: _timestamp(
        _integer(json['updatedAt'], 'updatedAt'),
        'updatedAt',
      ),
      note: _optionalText(json['note'] as String?),
      deletedAt: deletedAt == null ? null : _timestamp(deletedAt, 'deletedAt'),
    );
  }

  final String id;
  final String bookKey;
  final NovelAnnotationRange range;
  final String colorId;
  final int createdAt;
  final int updatedAt;
  final String? note;
  final int? deletedAt;

  bool get isDeleted => deletedAt != null;

  NovelAnnotation copyWith({
    NovelAnnotationRange? range,
    String? colorId,
    String? note,
    bool clearNote = false,
    int? updatedAt,
    int? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return NovelAnnotation(
      id: id,
      bookKey: bookKey,
      range: range ?? this.range,
      colorId: colorId ?? this.colorId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      note: clearNote ? null : _optionalText(note ?? this.note),
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
    );
  }

  NovelAnnotation deleted(int timestamp) => copyWith(
        updatedAt: timestamp,
        deletedAt: timestamp,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'bookKey': bookKey,
        'range': range.toJson(),
        'colorId': colorId,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (note != null) 'note': note,
        if (deletedAt != null) 'deletedAt': deletedAt,
      };
}

class NovelReaderBookData {
  NovelReaderBookData({
    required String bookKey,
    Map<String, NovelBookmark> bookmarks = const {},
    Map<String, NovelAnnotation> annotations = const {},
  })  : bookKey = _notBlank(bookKey, 'bookKey'),
        bookmarks = Map.unmodifiable(bookmarks),
        annotations = Map.unmodifiable(annotations) {
    for (final entry in bookmarks.entries) {
      if (entry.key != entry.value.id || entry.value.bookKey != bookKey) {
        throw const FormatException('Invalid bookmark ownership.');
      }
    }
    for (final entry in annotations.entries) {
      if (entry.key != entry.value.id || entry.value.bookKey != bookKey) {
        throw const FormatException('Invalid annotation ownership.');
      }
    }
  }

  factory NovelReaderBookData.empty(String bookKey) =>
      NovelReaderBookData(bookKey: bookKey);

  factory NovelReaderBookData.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Unsupported novel reader data schema.');
    }
    final bookKey = _notBlank(_string(json['bookKey'], 'bookKey'), 'bookKey');
    final bookmarks = <String, NovelBookmark>{};
    for (final entry in _map(json['bookmarks'], 'bookmarks').entries) {
      final value = NovelBookmark.fromJson(_map(entry.value, entry.key));
      bookmarks[entry.key] = value;
    }
    final annotations = <String, NovelAnnotation>{};
    for (final entry in _map(json['annotations'], 'annotations').entries) {
      final value = NovelAnnotation.fromJson(_map(entry.value, entry.key));
      annotations[entry.key] = value;
    }
    return NovelReaderBookData(
      bookKey: bookKey,
      bookmarks: bookmarks,
      annotations: annotations,
    );
  }

  final String bookKey;
  final Map<String, NovelBookmark> bookmarks;
  final Map<String, NovelAnnotation> annotations;

  NovelReaderBookData copyWith({
    Map<String, NovelBookmark>? bookmarks,
    Map<String, NovelAnnotation>? annotations,
  }) {
    return NovelReaderBookData(
      bookKey: bookKey,
      bookmarks: bookmarks ?? this.bookmarks,
      annotations: annotations ?? this.annotations,
    );
  }

  Map<String, Object?> toJson() => {
        'schema': 1,
        'bookKey': bookKey,
        'bookmarks': {
          for (final entry in bookmarks.entries)
            entry.key: entry.value.toJson(),
        },
        'annotations': {
          for (final entry in annotations.entries)
            entry.key: entry.value.toJson(),
        },
      };
}

NovelReaderBookData mergeNovelReaderBookData(
  NovelReaderBookData local,
  NovelReaderBookData remote,
) {
  if (local.bookKey != remote.bookKey) {
    throw ArgumentError('Cannot merge reader data for different books.');
  }
  return NovelReaderBookData(
    bookKey: local.bookKey,
    bookmarks: _mergeByTimestamp(
      local.bookmarks,
      remote.bookmarks,
      (value) => value.updatedAt,
    ),
    annotations: _mergeByTimestamp(
      local.annotations,
      remote.annotations,
      (value) => value.updatedAt,
    ),
  );
}

Map<String, dynamic> sanitizePortableNovelReaderData(Object? value) {
  if (value is! Map || value['schema'] != 1 || value['books'] is! Map) {
    return <String, dynamic>{'schema': 1, 'books': <String, dynamic>{}};
  }
  final books = <String, NovelReaderBookData>{};
  for (final entry in (value['books'] as Map).entries) {
    if (entry.key is! String || entry.value is! Map) continue;
    try {
      final book = NovelReaderBookData.fromJson(
        (entry.value as Map).cast<String, dynamic>(),
      );
      if (book.bookKey == entry.key) books[book.bookKey] = book;
    } catch (_) {
      continue;
    }
  }
  return _portableReaderDataFromBooks(books);
}

Map<String, dynamic> mergePortableNovelReaderData(
  Object? local,
  Object? remote,
) {
  final localBooks = _portableReaderBooks(local);
  final remoteBooks = _portableReaderBooks(remote);
  final merged = <String, NovelReaderBookData>{...localBooks};
  for (final entry in remoteBooks.entries) {
    final current = merged[entry.key];
    merged[entry.key] = current == null
        ? entry.value
        : mergeNovelReaderBookData(current, entry.value);
  }
  return _portableReaderDataFromBooks(merged);
}

Map<String, NovelReaderBookData> _portableReaderBooks(Object? value) {
  final sanitized = sanitizePortableNovelReaderData(value);
  final books = <String, NovelReaderBookData>{};
  for (final entry in (sanitized['books'] as Map).entries) {
    books[entry.key as String] = NovelReaderBookData.fromJson(
      (entry.value as Map).cast<String, dynamic>(),
    );
  }
  return books;
}

Map<String, dynamic> _portableReaderDataFromBooks(
  Map<String, NovelReaderBookData> books,
) {
  final bookKeys = books.keys.toList()..sort();
  return <String, dynamic>{
    'schema': 1,
    'books': <String, dynamic>{
      for (final bookKey in bookKeys)
        bookKey: _sortedNovelReaderBookJson(books[bookKey]!),
    },
  };
}

Map<String, dynamic> _sortedNovelReaderBookJson(NovelReaderBookData book) {
  final bookmarkIds = book.bookmarks.keys.toList()..sort();
  final annotationIds = book.annotations.keys.toList()..sort();
  return <String, dynamic>{
    'schema': 1,
    'bookKey': book.bookKey,
    'bookmarks': <String, dynamic>{
      for (final id in bookmarkIds) id: book.bookmarks[id]!.toJson(),
    },
    'annotations': <String, dynamic>{
      for (final id in annotationIds) id: book.annotations[id]!.toJson(),
    },
  };
}

Map<String, T> _mergeByTimestamp<T>(
  Map<String, T> local,
  Map<String, T> remote,
  int Function(T value) updatedAt,
) {
  final merged = <String, T>{...local};
  for (final entry in remote.entries) {
    final current = merged[entry.key];
    if (current == null || updatedAt(entry.value) >= updatedAt(current)) {
      merged[entry.key] = entry.value;
    }
  }
  return merged;
}

NovelLocator _portableLocator(NovelLocator locator) {
  return NovelLocator(
    chapterId: _notBlank(locator.chapterId, 'chapterId'),
    blockId: _optionalCapped(locator.blockId, 512),
    charOffset: locator.charOffset?.clamp(0, 1 << 31),
    quote: _optionalCapped(locator.quote, NovelReaderTextCaps.quote),
    prefix: _optionalCapped(locator.prefix, NovelReaderTextCaps.context),
    suffix: _optionalCapped(locator.suffix, NovelReaderTextCaps.context),
    fraction: locator.fraction,
  );
}

String _stableId(String kind, List<Object?> values) {
  return '$kind:${sha256.convert(utf8.encode(jsonEncode(values)))}';
}

String _cap(String value, int length) =>
    value.length <= length ? value : value.substring(0, length);

String? _optionalCapped(String? value, int length) {
  if (value == null) return null;
  return _cap(value, length);
}

String? _optionalText(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _notBlank(String value, String name) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw FormatException('$name must not be blank.');
  return trimmed;
}

String _string(Object? value, String name) {
  if (value is! String) throw FormatException('$name must be a string.');
  return value;
}

int _integer(Object? value, String name) {
  if (value is! num || !value.isFinite) {
    throw FormatException('$name must be an integer.');
  }
  return value.toInt();
}

int? _optionalInteger(Object? value, String name) =>
    value == null ? null : _integer(value, name);

int _timestamp(int value, String name) {
  if (value < 0) throw FormatException('$name must not be negative.');
  return value;
}

Map<String, dynamic> _map(Object? value, String name) {
  if (value is! Map) throw FormatException('$name must be an object.');
  return value.cast<String, dynamic>();
}
