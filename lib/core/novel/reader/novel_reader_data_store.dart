import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'novel_reader_data.dart';

typedef NovelReaderDataDirectory = Future<Directory> Function();
typedef NovelReaderDataClock = int Function();

class NovelReaderDataStore {
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
  bool _disposed = false;

  Future<File> fileForBook(String bookKey) async {
    final support = await _applicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}novel_reader_data',
    );
    await directory.create(recursive: true);
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
    _versions[data.bookKey] = (_versions[data.bookKey] ?? 0) + 1;
    _dirty.add(data.bookKey);
    _timers.remove(data.bookKey)?.cancel();
    _timers[data.bookKey] = Timer(writeDelay, () {
      _timers.remove(data.bookKey);
      unawaited(_flushBook(data.bookKey).catchError((_) {}));
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

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}
