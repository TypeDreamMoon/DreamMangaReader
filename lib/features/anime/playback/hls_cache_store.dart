import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

typedef CacheClock = DateTime Function();
typedef CacheDownloader = Future<CacheDownloadResult> Function(File file);

class HlsCacheRequest {
  const HlsCacheRequest({
    required this.url,
    required this.authScope,
    this.rangeStart,
    this.rangeLength,
  });

  final String url;
  final String authScope;
  final int? rangeStart;
  final int? rangeLength;
}

class CacheDownloadResult {
  const CacheDownloadResult({
    required this.contentType,
    this.expectedLength,
  });

  final String contentType;
  final int? expectedLength;
}

class HlsCacheLease {
  HlsCacheLease._({
    required this.file,
    required this.contentType,
    required Future<void> Function() onRelease,
  }) : _onRelease = onRelease;

  final File file;
  final String contentType;
  final Future<void> Function() _onRelease;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _onRelease();
  }
}

class HlsCacheWriter {
  HlsCacheWriter._({
    required this.sink,
    required Future<HlsCacheLease> Function({
      required String contentType,
      int? expectedLength,
    }) onCommit,
    required Future<void> Function() onAbort,
  })  : _onCommit = onCommit,
        _onAbort = onAbort;

  final IOSink sink;
  final Future<HlsCacheLease> Function({
    required String contentType,
    int? expectedLength,
  }) _onCommit;
  final Future<void> Function() _onAbort;
  bool _completed = false;

  Future<HlsCacheLease> commit({
    required String contentType,
    int? expectedLength,
  }) {
    if (_completed) throw StateError('缓存写入已经结束');
    _completed = true;
    return _onCommit(
      contentType: contentType,
      expectedLength: expectedLength,
    );
  }

  Future<void> abort() async {
    if (_completed) return;
    _completed = true;
    await _onAbort();
  }
}

class HlsCacheStore {
  HlsCacheStore({
    required this.directory,
    required int limitBytes,
    CacheClock? now,
  })  : _limitBytes = limitBytes,
        _now = now ?? DateTime.now;

  final Directory directory;
  final CacheClock _now;
  final Map<String, _CacheEntry> _entries = {};
  final Map<String, Future<_CacheEntry>> _inFlight = {};
  final Map<String, int> _inUse = {};
  int _limitBytes;
  Future<void>? _initializeFuture;
  Future<void> _persistTail = Future.value();

  File get _indexFile =>
      File('${directory.path}${Platform.pathSeparator}index.json');

  Future<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    await directory.create(recursive: true);
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.tmp')) {
        await entity.delete();
      }
    }
    if (!await _indexFile.exists()) return;
    try {
      final root =
          jsonDecode(await _indexFile.readAsString()) as Map<String, dynamic>;
      final entries = (root['entries'] as List?) ?? const [];
      for (final value in entries) {
        final json = value as Map<String, dynamic>;
        final entry = _CacheEntry.fromJson(json);
        final file = _fileFor(entry.key);
        if (await file.exists() && await file.length() == entry.size) {
          _entries[entry.key] = entry;
        }
      }
    } on Object {
      _entries.clear();
    }
    await _evict();
    await _persist();
  }

  Future<HlsCacheLease> acquire(
    HlsCacheRequest request,
    CacheDownloader download,
  ) async {
    await initialize();
    final key = _keyFor(request);
    var entry = _entries[key];
    if (entry == null || !await _fileFor(key).exists()) {
      final future = _inFlight.putIfAbsent(
        key,
        () => _download(key, download),
      );
      try {
        entry = await future;
      } finally {
        if (identical(_inFlight[key], future)) _inFlight.remove(key);
      }
    }
    entry.lastAccessMs = _now().millisecondsSinceEpoch;
    _entries[key] = entry;
    _inUse[key] = (_inUse[key] ?? 0) + 1;
    await _evict();
    await _persist();
    return HlsCacheLease._(
      file: _fileFor(key),
      contentType: entry.contentType,
      onRelease: () => _release(key),
    );
  }

  Future<HlsCacheLease?> lookup(HlsCacheRequest request) async {
    await initialize();
    final key = _keyFor(request);
    final entry = _entries[key];
    if (entry == null || !await _fileFor(key).exists()) return null;
    return _lease(key, entry);
  }

  Future<HlsCacheWriter> beginWrite(HlsCacheRequest request) async {
    await initialize();
    final key = _keyFor(request);
    if (_inFlight.containsKey(key)) {
      throw StateError('相同缓存资源正在写入');
    }
    final temporary = _temporaryFileFor(key);
    if (await temporary.exists()) await temporary.delete();
    final completer = Completer<_CacheEntry>();
    final future = completer.future;
    _inFlight[key] = future;
    unawaited(future.then<void>((_) {}, onError: (_) {}));
    final sink = temporary.openWrite();

    Future<void> finishInFlight() async {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }

    return HlsCacheWriter._(
      sink: sink,
      onCommit: ({required contentType, expectedLength}) async {
        try {
          await sink.flush();
          await sink.close();
          final size = await temporary.length();
          if (expectedLength != null && size != expectedLength) {
            throw StateError('缓存下载长度不完整');
          }
          final target = _fileFor(key);
          if (await target.exists()) await target.delete();
          await temporary.rename(target.path);
          final entry = _CacheEntry(
            key: key,
            size: size,
            lastAccessMs: _now().millisecondsSinceEpoch,
            contentType: contentType,
          );
          _entries[key] = entry;
          completer.complete(entry);
          await finishInFlight();
          return _lease(key, entry);
        } catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
          await finishInFlight();
          if (await temporary.exists()) await temporary.delete();
          rethrow;
        }
      },
      onAbort: () async {
        try {
          await sink.close();
        } finally {
          final error = StateError('缓存流式写入已取消');
          if (!completer.isCompleted) completer.completeError(error);
          await finishInFlight();
          if (await temporary.exists()) await temporary.delete();
        }
      },
    );
  }

  Future<HlsCacheLease> _lease(String key, _CacheEntry entry) async {
    entry.lastAccessMs = _now().millisecondsSinceEpoch;
    _entries[key] = entry;
    _inUse[key] = (_inUse[key] ?? 0) + 1;
    await _evict();
    await _persist();
    return HlsCacheLease._(
      file: _fileFor(key),
      contentType: entry.contentType,
      onRelease: () => _release(key),
    );
  }

  Future<_CacheEntry> _download(String key, CacheDownloader download) async {
    final temporary = _temporaryFileFor(key);
    if (await temporary.exists()) await temporary.delete();
    try {
      final result = await download(temporary);
      if (!await temporary.exists()) {
        throw StateError('缓存下载未生成临时文件');
      }
      final size = await temporary.length();
      if (result.expectedLength != null && size != result.expectedLength) {
        throw StateError('缓存下载长度不完整');
      }
      final target = _fileFor(key);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
      return _CacheEntry(
        key: key,
        size: size,
        lastAccessMs: _now().millisecondsSinceEpoch,
        contentType: result.contentType,
      );
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> _release(String key) async {
    final count = _inUse[key] ?? 0;
    if (count <= 1) {
      _inUse.remove(key);
    } else {
      _inUse[key] = count - 1;
    }
    await _evict();
    await _persist();
  }

  Future<int> sizeBytes() async {
    await initialize();
    return _entries.values.fold<int>(0, (total, entry) => total + entry.size);
  }

  Future<void> setLimitBytes(int value) async {
    if (value < 0) throw ArgumentError.value(value, 'value', '不能小于零');
    await initialize();
    _limitBytes = value;
    await _evict();
    await _persist();
  }

  Future<void> clear() async {
    await initialize();
    for (final entry in List<_CacheEntry>.of(_entries.values)) {
      if ((_inUse[entry.key] ?? 0) == 0) await _remove(entry);
    }
    await _persist();
  }

  Future<void> _evict() async {
    var total = _entries.values.fold<int>(0, (sum, entry) => sum + entry.size);
    if (total <= _limitBytes) return;
    final candidates = _entries.values
        .where((entry) => (_inUse[entry.key] ?? 0) == 0)
        .toList()
      ..sort((left, right) => left.lastAccessMs.compareTo(right.lastAccessMs));
    for (final entry in candidates) {
      if (total <= _limitBytes) break;
      await _remove(entry);
      total -= entry.size;
    }
  }

  Future<void> _remove(_CacheEntry entry) async {
    _entries.remove(entry.key);
    final file = _fileFor(entry.key);
    if (await file.exists()) await file.delete();
  }

  Future<void> _persist() {
    final encoded = jsonEncode({
      'schemaVersion': 1,
      'entries': _entries.values.map((entry) => entry.toJson()).toList(),
    });
    _persistTail = _persistTail.catchError((_) {}).then((_) async {
      final temporary = File('${_indexFile.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      if (await _indexFile.exists()) await _indexFile.delete();
      await temporary.rename(_indexFile.path);
    });
    return _persistTail;
  }

  String _keyFor(HlsCacheRequest request) {
    final uri = Uri.parse(request.url).replace(fragment: '');
    final material = [
      uri.toString(),
      request.authScope,
      request.rangeStart?.toString() ?? '',
      request.rangeLength?.toString() ?? '',
    ].join('\n');
    return sha256.convert(utf8.encode(material)).toString();
  }

  File _fileFor(String key) =>
      File('${directory.path}${Platform.pathSeparator}$key.bin');

  File _temporaryFileFor(String key) =>
      File('${directory.path}${Platform.pathSeparator}$key.tmp');
}

class _CacheEntry {
  _CacheEntry({
    required this.key,
    required this.size,
    required this.lastAccessMs,
    required this.contentType,
  });

  factory _CacheEntry.fromJson(Map<String, dynamic> json) => _CacheEntry(
        key: json['key'] as String,
        size: (json['size'] as num).toInt(),
        lastAccessMs: (json['lastAccessMs'] as num).toInt(),
        contentType: json['contentType'] as String,
      );

  final String key;
  final int size;
  int lastAccessMs;
  final String contentType;

  Map<String, Object> toJson() => {
        'key': key,
        'size': size,
        'lastAccessMs': lastAccessMs,
        'contentType': contentType,
      };
}
