import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/downloads/content_download_task.dart';
import '../core/downloads/download_executor.dart';
import '../core/downloads/download_task.dart';
import '../core/novel/models.dart';
import '../core/novel/novel_document_cache.dart';
import '../core/novel/novel_source.dart';
import '../core/source/source_registry.dart';

typedef NovelDownloadRootProvider = Future<String> Function();
typedef NovelSourceBuilder = NovelSource Function(SourceMeta meta);
typedef NovelDocumentCacheFactory = NovelDocumentCache Function(String root);

class DownloadedNovelChapter {
  const DownloadedNovelChapter({
    required this.source,
    required this.novel,
    required this.chapter,
    required this.directory,
    required this.resourceCount,
    required this.byteCount,
    required this.completedAt,
  });

  final SourceMeta source;
  final Novel novel;
  final NovelChapter chapter;
  final String directory;
  final int resourceCount;
  final int byteCount;
  final int completedAt;

  String get sourceId => source.id;
  String get novelId => novel.id;
  String get chapterId => chapter.id;

  Map<String, Object?> toJson() => {
        'source': _sourceToJson(source),
        'novel': _novelToJson(novel),
        'chapter': _chapterToJson(chapter),
        'directory': directory,
        'resourceCount': resourceCount,
        'byteCount': byteCount,
        'completedAt': completedAt,
      };

  factory DownloadedNovelChapter.fromJson(Map<String, dynamic> json) {
    return DownloadedNovelChapter(
      source: _sourceFromJson(_requiredMap(json, 'source')),
      novel: _novelFromJson(_requiredMap(json, 'novel')),
      chapter: _chapterFromJson(_requiredMap(json, 'chapter')),
      directory: json['directory'] as String,
      resourceCount: (json['resourceCount'] as num).toInt(),
      byteCount: (json['byteCount'] as num).toInt(),
      completedAt: (json['completedAt'] as num).toInt(),
    );
  }

  DownloadedNovelChapter withCache(CachedNovelDocument cached) {
    return DownloadedNovelChapter(
      source: source,
      novel: novel,
      chapter: chapter,
      directory: cached.directory,
      resourceCount: cached.resourceCount,
      byteCount: cached.byteCount,
      completedAt: completedAt,
    );
  }
}

class NovelDownloadFailure {
  const NovelDownloadFailure({
    required this.source,
    required this.novel,
    required this.chapter,
    required this.error,
    required this.failedAt,
  });

  final SourceMeta source;
  final Novel novel;
  final NovelChapter chapter;
  final Object error;
  final int failedAt;

  String get message => error.toString();
}

class NovelDownloadActivity {
  const NovelDownloadActivity({
    required this.source,
    required this.novel,
    required this.chapter,
    required this.progress,
  });

  final SourceMeta source;
  final Novel novel;
  final NovelChapter chapter;
  final double progress;
}

class _NovelDownloadJob {
  const _NovelDownloadJob(
    this.source,
    this.novel,
    this.chapter,
    this.generation,
  );

  final SourceMeta source;
  final Novel novel;
  final NovelChapter chapter;
  final int generation;

  String get key => _chapterKey(source.id, novel.id, chapter.id);
}

class NovelDownloadStore extends ChangeNotifier implements DownloadExecutor {
  NovelDownloadStore({
    NovelDownloadRootProvider? rootProvider,
    NovelSourceBuilder sourceBuilder = buildNovelSource,
    NovelDocumentCacheFactory? cacheFactory,
  })  : _rootProvider = rootProvider ?? _applicationSupportRoot,
        _sourceBuilder = sourceBuilder,
        _cacheFactory = cacheFactory ?? _defaultCacheFactory;

  static const _indexKey = 'novel.downloads.v1';

  final NovelDownloadRootProvider _rootProvider;
  final NovelSourceBuilder _sourceBuilder;
  final NovelDocumentCacheFactory _cacheFactory;
  final Map<String, DownloadedNovelChapter> _completed = {};
  final Map<String, double> _progress = {};
  final Map<String, NovelDownloadFailure> _failures = {};
  final Map<String, int> _generations = {};
  final List<_NovelDownloadJob> _queue = [];

  SharedPreferences? _prefs;
  NovelDocumentCache? _cache;
  _NovelDownloadJob? _activeJob;
  Completer<void>? _idleCompleter;
  bool _running = false;
  bool _disposed = false;

  List<DownloadedNovelChapter> get downloads {
    final result = _completed.values.toList(growable: false)
      ..sort((a, b) => b.completedAt.compareTo(a.completedAt));
    return List.unmodifiable(result);
  }

  List<NovelDownloadFailure> get failures =>
      List.unmodifiable(_failures.values);

  List<NovelDownloadActivity> get activities {
    final jobs = <_NovelDownloadJob>[
      if (_activeJob != null) _activeJob!,
      ..._queue,
    ];
    return List.unmodifiable([
      for (final job in jobs)
        if (_progress[job.key] case final progress?)
          NovelDownloadActivity(
            source: job.source,
            novel: job.novel,
            chapter: job.chapter,
            progress: progress,
          ),
    ]);
  }

  int get activeCount => _progress.length;

  @override
  DownloadContentKind get kind => DownloadContentKind.novel;

  @override
  Future<void> execute(
    DownloadExecutionContext context,
    DownloadTask task,
  ) async {
    final request = ContentDownloadRequest.fromTask(task);
    final source = _sourceById(request.sourceId);
    if (!source.isNovel) {
      throw StateError('source is not a novel source: ${source.id}');
    }
    final job = _NovelDownloadJob(
      source,
      Novel(id: request.contentId, title: task.title),
      NovelChapter(id: request.chapterId, title: task.itemTitle),
      0,
    );
    if (_completed.containsKey(job.key)) return;
    _progress[job.key] = 0;
    _notify();
    try {
      await _download(job, context: context);
      _failures.remove(job.key);
    } catch (error) {
      if (!context.cancellation.isCancelled) {
        _failures[job.key] = NovelDownloadFailure(
          source: job.source,
          novel: job.novel,
          chapter: job.chapter,
          error: error,
          failedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
      rethrow;
    } finally {
      _progress.remove(job.key);
      _notify();
    }
  }

  Future<void> get idle {
    if (!_running && _queue.isEmpty) return Future.value();
    return (_idleCompleter ??= Completer<void>()).future;
  }

  Future<void> load() async {
    final values = await Future.wait<Object>([
      SharedPreferences.getInstance(),
      _rootProvider(),
    ]);
    if (_disposed) return;
    final prefs = values[0] as SharedPreferences;
    final cache = _cacheFactory(values[1] as String);
    final loaded = <String, DownloadedNovelChapter>{};
    var repairIndex = false;
    final raw = prefs.getString(_indexKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) {
          repairIndex = true;
        } else {
          for (final value in decoded) {
            if (value is! Map) {
              repairIndex = true;
              continue;
            }
            try {
              final record = DownloadedNovelChapter.fromJson(
                value.cast<String, dynamic>(),
              );
              final cached = await cache.read(
                record.sourceId,
                record.novelId,
                record.chapterId,
              );
              if (cached == null) {
                repairIndex = true;
                continue;
              }
              final key = _chapterKey(
                record.sourceId,
                record.novelId,
                record.chapterId,
              );
              if (loaded.containsKey(key) ||
                  record.directory != cached.directory ||
                  record.resourceCount != cached.resourceCount ||
                  record.byteCount != cached.byteCount) {
                repairIndex = true;
              }
              loaded[key] = record.withCache(cached);
            } catch (_) {
              repairIndex = true;
            }
          }
        }
      } catch (_) {
        repairIndex = true;
      }
    }
    if (_disposed) return;
    _prefs = prefs;
    _cache = cache;
    _completed
      ..clear()
      ..addAll(loaded);
    if (repairIndex) await _persist();
    _notify();
  }

  bool isDownloaded(String sourceId, String novelId, String chapterId) =>
      _completed.containsKey(_chapterKey(sourceId, novelId, chapterId));

  double? progressOf(String sourceId, String novelId, String chapterId) =>
      _progress[_chapterKey(sourceId, novelId, chapterId)];

  NovelDownloadFailure? failureOf(
    String sourceId,
    String novelId,
    String chapterId,
  ) =>
      _failures[_chapterKey(sourceId, novelId, chapterId)];

  Future<CachedNovelDocument?> localDocument(
    String sourceId,
    String novelId,
    String chapterId,
  ) async {
    final key = _chapterKey(sourceId, novelId, chapterId);
    if (!_completed.containsKey(key)) return null;
    return _requireCache().read(sourceId, novelId, chapterId);
  }

  void enqueue(SourceMeta source, Novel novel, NovelChapter chapter) {
    _ensureReady();
    final key = _chapterKey(source.id, novel.id, chapter.id);
    if (_completed.containsKey(key) ||
        _progress.containsKey(key) ||
        _failures.containsKey(key)) {
      return;
    }
    final generation = (_generations[key] ?? 0) + 1;
    _generations[key] = generation;
    final job = _NovelDownloadJob(source, novel, chapter, generation);
    _progress[job.key] = 0;
    _queue.add(job);
    _idleCompleter ??= Completer<void>();
    _notify();
    unawaited(_pump());
  }

  void retry(String sourceId, String novelId, String chapterId) {
    final key = _chapterKey(sourceId, novelId, chapterId);
    final failure = _failures.remove(key);
    if (failure == null) return;
    _notify();
    enqueue(failure.source, failure.novel, failure.chapter);
  }

  Future<void> deleteChapter(
    String sourceId,
    String novelId,
    String chapterId,
  ) async {
    await _deleteChapter(sourceId, novelId, chapterId);
    await _persist();
    _notify();
  }

  Future<void> deleteNovel(String sourceId, String novelId) async {
    final identities = <(String, String, String)>{};
    for (final record in _completed.values) {
      if (record.sourceId == sourceId && record.novelId == novelId) {
        identities.add((sourceId, novelId, record.chapterId));
      }
    }
    for (final failure in _failures.values) {
      if (failure.source.id == sourceId && failure.novel.id == novelId) {
        identities.add((sourceId, novelId, failure.chapter.id));
      }
    }
    for (final job in [..._queue, if (_activeJob != null) _activeJob!]) {
      if (job.source.id == sourceId && job.novel.id == novelId) {
        identities.add((sourceId, novelId, job.chapter.id));
      }
    }
    for (final identity in identities) {
      await _deleteChapter(identity.$1, identity.$2, identity.$3);
    }
    await _persist();
    _notify();
  }

  Future<void> _deleteChapter(
    String sourceId,
    String novelId,
    String chapterId,
  ) async {
    final key = _chapterKey(sourceId, novelId, chapterId);
    _generations[key] = (_generations[key] ?? 0) + 1;
    _completed.remove(key);
    _failures.remove(key);
    _progress.remove(key);
    _queue.removeWhere((job) => job.key == key);
    await _deleteCachedDocument(sourceId, novelId, chapterId);
  }

  Future<void> _pump() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final job = _queue.removeAt(0);
        _activeJob = job;
        await _run(job);
        _activeJob = null;
      }
    } finally {
      _activeJob = null;
      _running = false;
      if (_queue.isEmpty || _disposed) {
        final completer = _idleCompleter;
        _idleCompleter = null;
        if (completer != null && !completer.isCompleted) completer.complete();
      } else {
        unawaited(_pump());
      }
    }
  }

  Future<void> _run(_NovelDownloadJob job) async {
    try {
      await _download(job);
      _failures.remove(job.key);
    } catch (error) {
      if (!_isCancelled(job)) {
        _failures[job.key] = NovelDownloadFailure(
          source: job.source,
          novel: job.novel,
          chapter: job.chapter,
          error: error,
          failedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
    } finally {
      if (_generations[job.key] == job.generation) {
        _progress.remove(job.key);
      }
      _notify();
    }
  }

  Future<void> _download(
    _NovelDownloadJob job, {
    DownloadExecutionContext? context,
  }) async {
    NovelSource? source;
    CachedNovelDocument? cached;
    try {
      _throwIfCancelled(job, context);
      _progress[job.key] = 0.2;
      _notify();
      source = _sourceBuilder(job.source);
      final document = await source.getNovelDocument(
        job.novel.id,
        job.chapter.id,
      );
      _throwIfCancelled(job, context);
      _progress[job.key] = 0.6;
      _notify();
      cached = await _requireCache().save(
        job.source.id,
        job.novel.id,
        job.chapter.id,
        document,
        headers: imageHeadersOf(job.source),
      );
      try {
        _throwIfCancelled(job, context);
      } on DownloadCancelledException {
        await _deleteDirectory(cached.directory);
        rethrow;
      }
      final record = DownloadedNovelChapter(
        source: job.source,
        novel: job.novel,
        chapter: job.chapter,
        directory: cached.directory,
        resourceCount: cached.resourceCount,
        byteCount: cached.byteCount,
        completedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _completed[job.key] = record;
      try {
        await _persist();
      } catch (_) {
        _completed.remove(job.key);
        await _deleteDirectory(cached.directory);
        rethrow;
      }
      await context?.reportProgress(cached.byteCount, cached.byteCount);
    } finally {
      try {
        source?.dispose();
      } catch (_) {}
    }
  }

  void _throwIfCancelled(
    _NovelDownloadJob job,
    DownloadExecutionContext? context,
  ) {
    if (_disposed) throw const DownloadCancelledException();
    if (context != null) {
      context.cancellation.throwIfCancelled();
    } else if (_isCancelled(job)) {
      throw const DownloadCancelledException();
    }
  }

  Future<void> _deleteCachedDocument(
    String sourceId,
    String novelId,
    String chapterId,
  ) async {
    final cached = await _requireCache().read(sourceId, novelId, chapterId);
    if (cached != null) await _deleteDirectory(cached.directory);
  }

  Future<void> _deleteDirectory(String path) async {
    final directory = Directory(path);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final stored = await prefs.setString(
      _indexKey,
      jsonEncode(_completed.values.map((value) => value.toJson()).toList()),
    );
    if (!stored) throw StateError('Failed to persist novel download index');
  }

  bool _isCancelled(_NovelDownloadJob job) =>
      _disposed || _generations[job.key] != job.generation;

  SourceMeta _sourceById(String id) {
    for (final source in registeredSources) {
      if (source.id == id) return source;
    }
    throw StateError('novel source is unavailable: $id');
  }

  NovelDocumentCache _requireCache() {
    final cache = _cache;
    if (cache == null) throw StateError('NovelDownloadStore is not loaded');
    return cache;
  }

  void _ensureReady() {
    if (_disposed) throw StateError('NovelDownloadStore is disposed');
    _requireCache();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    _progress.clear();
    super.dispose();
  }
}

class NovelDownloadScope extends InheritedNotifier<NovelDownloadStore> {
  const NovelDownloadScope({
    super.key,
    required NovelDownloadStore store,
    required super.child,
  }) : super(notifier: store);

  static NovelDownloadStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<NovelDownloadScope>();
    assert(scope != null, 'NovelDownloadScope not found in context');
    return scope!.notifier!;
  }

  static NovelDownloadStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<NovelDownloadScope>();
    assert(scope != null, 'NovelDownloadScope not found in context');
    return scope!.notifier!;
  }

  static NovelDownloadStore? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NovelDownloadScope>()?.notifier;
}

Future<String> _applicationSupportRoot() async =>
    (await getApplicationSupportDirectory()).path;

NovelDocumentCache _defaultCacheFactory(String root) =>
    NovelDocumentCache(root: root, dio: Dio());

String _chapterKey(String sourceId, String novelId, String chapterId) =>
    jsonEncode([sourceId, novelId, chapterId]);

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return value.cast<String, dynamic>();
}

Map<String, Object?> _sourceToJson(SourceMeta source) => {
      'id': source.id,
      'name': source.name,
      'script': source.script,
      'kind': source.kind,
      'experimental': source.experimental,
      'useWebView': source.useWebView,
      'imageReferer': source.imageReferer,
      'needsLogin': source.needsLogin,
      'authKey': source.authKey,
    };

SourceMeta _sourceFromJson(Map<String, dynamic> json) => SourceMeta(
      id: json['id'] as String,
      name: json['name'] as String,
      script: json['script'] as String,
      kind: json['kind'] as String? ?? 'novel',
      experimental: json['experimental'] as bool? ?? false,
      useWebView: json['useWebView'] as bool? ?? false,
      imageReferer: json['imageReferer'] as String?,
      needsLogin: json['needsLogin'] as bool? ?? false,
      authKey: json['authKey'] as String?,
    );

Map<String, Object?> _novelToJson(Novel novel) => {
      'id': novel.id,
      'title': novel.title,
      'url': novel.url,
      'cover': novel.cover,
      'authors': novel.authors,
      'genres': novel.genres,
      'description': novel.description,
      'status': novel.status.name,
      'updatedAt': novel.updatedAt,
    };

Novel _novelFromJson(Map<String, dynamic> json) => Novel(
      id: json['id'] as String,
      title: json['title'] as String,
      url: json['url'] as String?,
      cover: json['cover'] as String?,
      authors: _stringList(json['authors']),
      genres: _stringList(json['genres']),
      description: json['description'] as String?,
      status: NovelStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => NovelStatus.unknown,
      ),
      updatedAt: (json['updatedAt'] as num?)?.toInt(),
    );

Map<String, Object?> _chapterToJson(NovelChapter chapter) => {
      'id': chapter.id,
      'title': chapter.title,
      'number': chapter.number,
      'publishedAt': chapter.publishedAt,
      'volumeId': chapter.volumeId,
      'volumeTitle': chapter.volumeTitle,
      'epubAnchor': chapter.epubAnchor,
    };

NovelChapter _chapterFromJson(Map<String, dynamic> json) => NovelChapter(
      id: json['id'] as String,
      title: json['title'] as String,
      number: (json['number'] as num?)?.toDouble(),
      publishedAt: (json['publishedAt'] as num?)?.toInt(),
      volumeId: json['volumeId'] as String?,
      volumeTitle: json['volumeTitle'] as String?,
      epubAnchor: json['epubAnchor'] as String?,
    );

List<String> _stringList(Object? value) =>
    (value as List? ?? const []).map((item) => item.toString()).toList();
