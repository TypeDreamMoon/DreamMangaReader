import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'novel_reader_data.dart';

typedef NovelReaderDataDirectory = Future<Directory> Function();
typedef NovelReaderDataClock = int Function();

class NovelReaderDataStore extends ChangeNotifier {
  NovelReaderDataStore({
    NovelReaderDataDirectory? applicationSupportDirectory,
    this.writeDelay = const Duration(milliseconds: 350),
    NovelReaderDataClock? clock,
  })  : _applicationSupportDirectory =
            applicationSupportDirectory ?? getApplicationSupportDirectory,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final NovelReaderDataDirectory _applicationSupportDirectory;
  final Duration writeDelay;
  final NovelReaderDataClock _clock;
  final Map<String, NovelReaderBookData> _cache = {};
  final Map<String, int> _versions = {};
  final Map<String, Timer> _timers = {};
  final Map<String, Future<void>> _writes = {};
  final Set<String> _dirty = {};
  Map<String, dynamic> _portableSnapshot = const {
    'schema': 1,
    'books': <String, dynamic>{},
  };
  bool _disposed = false;

  static final NovelReaderDataStore instance = NovelReaderDataStore();

  Map<String, dynamic> get portableSnapshot =>
      sanitizePortableNovelReaderData(_portableSnapshot);

  Future<Directory> _dataDirectory() async {
    final support = await _applicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}novel_reader_data',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> fileForBook(String bookKey) async {
    final directory = await _dataDirectory();
    final digest = sha256.convert(utf8.encode(bookKey)).toString();
    return File('${directory.path}${Platform.pathSeparator}$digest.json');
  }

  Future<NovelReaderBookData> loadBook(String bookKey) async {
    _ensureActive();
    final cached = _cache[bookKey];
    if (cached != null) return cached;
    final file = await fileForBook(bookKey);
    final temporary = File('${file.path}.tmp');
    final primary = await _readData(file, bookKey);
    final pending = await _readData(temporary, bookKey);

    NovelReaderBookData? loaded;
    if (pending != null) {
      if (await file.exists() && primary == null) await _retainCorrupt(file);
      await _promoteTemporary(temporary, file);
      loaded = pending;
    } else {
      if (await temporary.exists()) await _retainCorrupt(temporary);
      if (primary == null && await file.exists()) await _retainCorrupt(file);
      loaded = primary;
    }
    final result = loaded ?? NovelReaderBookData.empty(bookKey);
    _cache[bookKey] = result;
    return result;
  }

  void saveBook(NovelReaderBookData data) {
    _ensureActive();
    _cache[data.bookKey] = data;
    _updatePortableBook(data);
    _versions[data.bookKey] = (_versions[data.bookKey] ?? 0) + 1;
    _dirty.add(data.bookKey);
    _timers.remove(data.bookKey)?.cancel();
    _timers[data.bookKey] = Timer(writeDelay, () {
      _timers.remove(data.bookKey);
      unawaited(_flushBook(data.bookKey).catchError((_) {}));
    });
    notifyListeners();
  }

  Future<Map<String, dynamic>> exportPortableData() async {
    _ensureActive();
    await flushPending();
    final books = await _loadAllBooks();
    _portableSnapshot = sanitizePortableNovelReaderData({
      'schema': 1,
      'books': {
        for (final entry in books.entries) entry.key: entry.value.toJson(),
      },
    });
    return portableSnapshot;
  }

  Future<void> importPortableData(
    Object? value, {
    required bool append,
  }) async {
    _ensureActive();
    final incoming = _booksFromPortable(value);
    final current = await _loadAllBooks();
    final next = append
        ? <String, NovelReaderBookData>{
            ...current,
            for (final entry in incoming.entries)
              entry.key: current[entry.key] == null
                  ? entry.value
                  : mergeNovelReaderBookData(current[entry.key]!, entry.value),
          }
        : incoming;
    final keys = append
        ? next.keys.toSet()
        : <String>{...current.keys, ...incoming.keys};
    for (final bookKey in keys) {
      saveBook(next[bookKey] ?? NovelReaderBookData.empty(bookKey));
    }
    await flushPending();
    await exportPortableData();
  }

  Future<Map<String, NovelReaderBookData>> _loadAllBooks() async {
    final books = <String, NovelReaderBookData>{};
    final directory = await _dataDirectory();
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString(encoding: utf8));
        if (decoded is! Map) continue;
        final book = NovelReaderBookData.fromJson(
          decoded.cast<String, dynamic>(),
        );
        books[book.bookKey] = book;
      } catch (_) {
        continue;
      }
    }
    books.addAll(_cache);
    return books;
  }

  Map<String, NovelReaderBookData> _booksFromPortable(Object? value) {
    final sanitized = sanitizePortableNovelReaderData(value);
    return <String, NovelReaderBookData>{
      for (final entry in (sanitized['books'] as Map).entries)
        entry.key as String: NovelReaderBookData.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        ),
    };
  }

  void _updatePortableBook(NovelReaderBookData data) {
    final books = Map<String, dynamic>.from(
      (_portableSnapshot['books'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    books[data.bookKey] = data.toJson();
    _portableSnapshot = sanitizePortableNovelReaderData({
      'schema': 1,
      'books': books,
    });
  }

  Future<void> flushPending() async {
    _ensureActive();
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    while (_dirty.isNotEmpty || _writes.isNotEmpty) {
      final dirty = _dirty.toList(growable: false);
      await Future.wait(dirty.map(_flushBook));
      if (_writes.isNotEmpty) {
        await Future.wait(_writes.values.toList(growable: false));
      }
    }
  }

  Future<void> _flushBook(String bookKey) {
    final existing = _writes[bookKey];
    if (existing != null) return existing;
    late final Future<void> write;
    write = _writeUntilCurrent(bookKey).whenComplete(() {
      if (identical(_writes[bookKey], write)) _writes.remove(bookKey);
    });
    _writes[bookKey] = write;
    return write;
  }

  Future<void> _writeUntilCurrent(String bookKey) async {
    while (_dirty.contains(bookKey)) {
      final data = _cache[bookKey];
      if (data == null) {
        _dirty.remove(bookKey);
        return;
      }
      final version = _versions[bookKey] ?? 0;
      final file = await fileForBook(bookKey);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(data.toJson()),
        encoding: utf8,
        flush: true,
      );
      await _promoteTemporary(temporary, file);
      if ((_versions[bookKey] ?? 0) == version) {
        _dirty.remove(bookKey);
      }
    }
  }

  Future<NovelReaderBookData?> _readData(File file, String bookKey) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString(encoding: utf8));
      if (decoded is! Map) return null;
      final data = NovelReaderBookData.fromJson(
        decoded.cast<String, dynamic>(),
      );
      return data.bookKey == bookKey ? data : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _promoteTemporary(File temporary, File destination) async {
    final backup = File('${destination.path}.bak');
    if (await backup.exists()) await backup.delete();
    if (await destination.exists()) await destination.rename(backup.path);
    try {
      await temporary.rename(destination.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await destination.exists() && await backup.exists()) {
        await backup.rename(destination.path);
      }
      rethrow;
    }
  }

  Future<void> _retainCorrupt(File file) async {
    final target = File('${file.path}.corrupt-${_clock()}');
    if (await target.exists()) await target.delete();
    await file.rename(target.path);
  }

  void _ensureActive() {
    if (_disposed) throw StateError('NovelReaderDataStore is disposed.');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}
