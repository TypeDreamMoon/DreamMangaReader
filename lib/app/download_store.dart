import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/downloads/content_download_task.dart';
import '../core/downloads/download_executor.dart';
import '../core/downloads/download_task.dart';
import '../core/log/app_log.dart';
import '../core/net/image_cache.dart';
import '../core/source/models.dart';
import '../core/source/page_image_data.dart';
import '../core/source/source.dart';
import '../core/source/source_registry.dart';

typedef MangaDownloadRootProvider = Future<String> Function();
typedef MangaDownloadSourceBuilder = MangaSource Function(SourceMeta meta);
typedef MangaPageFetcher = Future<File> Function(
  String url,
  Map<String, String> headers,
);

/// 一话已下载的记录(足够离线渲染 + 在下载页展示)。
class DownloadedChapter {
  DownloadedChapter({
    required this.sourceId,
    required this.mangaId,
    required this.mangaTitle,
    this.mangaCover,
    required this.chapterId,
    required this.chapterName,
    required this.dir,
    required this.pageCount,
    required this.doneAt,
  });

  final String sourceId;
  final String mangaId;
  final String mangaTitle;
  final String? mangaCover;
  final String chapterId;
  final String chapterName;
  final String dir; // 本地目录
  final int pageCount;
  final int doneAt;

  String get key => '$sourceId:$mangaId:$chapterId';
  String get mangaKey => '$sourceId:$mangaId';
  List<String> get pagePaths =>
      [for (var i = 0; i < pageCount; i++) '$dir/$i.img'];

  Map<String, dynamic> toJson() => {
        's': sourceId,
        'm': mangaId,
        'mt': mangaTitle,
        'mc': mangaCover,
        'c': chapterId,
        'cn': chapterName,
        'd': dir,
        'p': pageCount,
        't': doneAt,
      };

  static DownloadedChapter fromJson(Map<String, dynamic> j) =>
      DownloadedChapter(
        sourceId: j['s'] as String,
        mangaId: j['m'] as String,
        mangaTitle: (j['mt'] as String?) ?? '',
        mangaCover: j['mc'] as String?,
        chapterId: j['c'] as String,
        chapterName: (j['cn'] as String?) ?? '',
        dir: j['d'] as String,
        pageCount: (j['p'] as num?)?.toInt() ?? 0,
        doneAt: (j['t'] as num?)?.toInt() ?? 0,
      );
}

class _Job {
  _Job(this.meta, this.manga, this.chapter, this.headers);
  final SourceMeta meta;
  final Manga manga;
  final Chapter chapter;
  final Map<String, String> headers;
  String get key => '${meta.id}:${manga.id}:${chapter.id}';
}

/// 离线下载管理:排队下载章节图片到本地,记录索引(可离线阅读)。
/// 沿用 ChangeNotifier + InheritedNotifier 模式。
class DownloadStore extends ChangeNotifier implements DownloadExecutor {
  DownloadStore({
    MangaDownloadRootProvider? rootProvider,
    MangaDownloadSourceBuilder sourceBuilder = buildSource,
    MangaPageFetcher pageFetcher = _defaultPageFetcher,
  })  : _rootProvider = rootProvider ?? _applicationDownloadsRoot,
        _sourceBuilder = sourceBuilder,
        _pageFetcher = pageFetcher;

  static const _kIndex = 'downloads.index';

  final MangaDownloadRootProvider _rootProvider;
  final MangaDownloadSourceBuilder _sourceBuilder;
  final MangaPageFetcher _pageFetcher;

  final Map<String, DownloadedChapter> _done = {};
  final Map<String, double> _progress = {}; // key → 0..1(进行中/排队)
  final List<_Job> _queue = [];
  bool _running = false;
  bool _disposed = false;

  SharedPreferences? _prefs;
  String? _root;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _root = await _rootProvider();
    try {
      final raw = _prefs!.getString(_kIndex);
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach((k, v) {
          _done[k as String] =
              DownloadedChapter.fromJson((v as Map).cast<String, dynamic>());
        });
      }
    } catch (_) {}
    notifyListeners();
  }

  bool isDownloaded(String s, String m, String c) =>
      _done.containsKey('$s:$m:$c');
  double? progressOf(String s, String m, String c) => _progress['$s:$m:$c'];

  /// 已下载章节的本地页路径(未下载返回 null)。
  List<String>? localPages(String s, String m, String c) =>
      _done['$s:$m:$c']?.pagePaths;

  /// 全部已下载章节,按漫画分组(mangaKey → 章节列表,最新下载在前)。
  Map<String, List<DownloadedChapter>> get byManga {
    final map = <String, List<DownloadedChapter>>{};
    for (final d in _done.values) {
      (map[d.mangaKey] ??= []).add(d);
    }
    for (final l in map.values) {
      l.sort((a, b) => b.doneAt.compareTo(a.doneAt));
    }
    return map;
  }

  int get activeCount => _progress.length;

  @override
  DownloadContentKind get kind => DownloadContentKind.manga;

  @override
  Future<void> execute(
    DownloadExecutionContext context,
    DownloadTask task,
  ) async {
    final request = ContentDownloadRequest.fromTask(task);
    final meta = _sourceById(request.sourceId);
    if (!meta.isManga) {
      throw StateError('source is not a manga source: ${meta.id}');
    }
    final job = _Job(
      meta,
      Manga(id: request.contentId, title: task.title),
      Chapter(id: request.chapterId, name: task.itemTitle),
      imageHeadersOf(meta),
    );
    if (_done.containsKey(job.key)) return;
    _progress[job.key] = 0;
    notifyListeners();
    try {
      await _download(job, context: context);
    } finally {
      _progress.remove(job.key);
      if (!_disposed) notifyListeners();
    }
  }

  void enqueue(SourceMeta meta, Manga manga, Chapter chapter,
      Map<String, String> headers) {
    final key = '${meta.id}:${manga.id}:${chapter.id}';
    if (_done.containsKey(key) || _progress.containsKey(key)) return;
    _progress[key] = 0;
    _queue.add(_Job(meta, manga, chapter, headers));
    notifyListeners();
    _pump();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    while (_queue.isNotEmpty && !_disposed) {
      await _run(_queue.removeAt(0));
    }
    _running = false;
  }

  Future<void> _run(_Job job) async {
    try {
      await _download(job);
    } catch (e) {
      final label = '《${job.manga.title}》${job.chapter.name}';
      AppLog.i.err(LogCat.download, '$label 下载出错', detail: '$e');
    }
    _progress.remove(job.key);
    if (!_disposed) notifyListeners();
  }

  Future<void> _download(
    _Job job, {
    DownloadExecutionContext? context,
  }) async {
    final root = _root;
    if (root == null) throw StateError('DownloadStore is not loaded');
    final label = '《${job.manga.title}》${job.chapter.name}';
    final sw = Stopwatch()..start();
    final source = _sourceBuilder(job.meta);
    AppLog.i.info(LogCat.download, '开始下载 $label', detail: '源:${job.meta.name}');
    try {
      context?.cancellation.throwIfCancelled();
      final pages = await source.getPages(job.manga.id, job.chapter.id);
      context?.cancellation.throwIfCancelled();
      if (pages.isEmpty) throw StateError('$label 没有可下载页面');
      final dir = Directory(
        '$root/${job.meta.id}/${_safe(job.manga.id)}/${_safe(job.chapter.id)}',
      );
      await dir.create(recursive: true);
      for (var i = 0; i < pages.length; i++) {
        if (_disposed) throw const DownloadCancelledException();
        context?.cancellation.throwIfCancelled();
        final headers = {...job.headers, ...?pages[i].headers};
        try {
          await writePageImage(
            image: pages[i],
            output: File('${dir.path}/$i.img'),
            headers: headers,
            fetchNetwork: _pageFetcher,
          );
        } catch (_) {
          try {
            await dir.delete(recursive: true);
          } catch (_) {}
          rethrow;
        }
        _progress[job.key] = (i + 1) / pages.length;
        if (!_disposed) notifyListeners();
        await context?.reportProgress(i + 1, pages.length);
      }
      final completed = DownloadedChapter(
        sourceId: job.meta.id,
        mangaId: job.manga.id,
        mangaTitle: job.manga.title,
        mangaCover: job.manga.cover,
        chapterId: job.chapter.id,
        chapterName: job.chapter.name,
        dir: dir.path,
        pageCount: pages.length,
        doneAt: DateTime.now().millisecondsSinceEpoch,
      );
      _done[job.key] = completed;
      try {
        await _persist();
      } catch (_) {
        _done.remove(job.key);
        rethrow;
      }
      if (!_disposed) notifyListeners();
      AppLog.i.success(
        LogCat.download,
        '下载完成 $label · ${pages.length} 页 · ${sw.elapsedMilliseconds}ms',
      );
    } finally {
      source.dispose();
    }
  }

  Future<void> deleteChapter(String key) async {
    final d = _done.remove(key);
    if (d == null) return;
    try {
      await Directory(d.dir).delete(recursive: true);
    } catch (_) {}
    await _persist();
    notifyListeners();
  }

  Future<void> deleteManga(String sourceId, String mangaId) async {
    final keys =
        _done.keys.where((k) => k.startsWith('$sourceId:$mangaId:')).toList();
    for (final k in keys) {
      await deleteChapter(k);
    }
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final stored = await prefs.setString(
      _kIndex,
      jsonEncode({for (final e in _done.entries) e.key: e.value.toJson()}),
    );
    if (!stored) throw StateError('Failed to persist manga download index');
  }

  SourceMeta _sourceById(String id) {
    for (final source in registeredSources) {
      if (source.id == id) return source;
    }
    throw StateError('manga source is unavailable: $id');
  }

  String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

Future<String> _applicationDownloadsRoot() async {
  final directory = await getApplicationSupportDirectory();
  return '${directory.path}/downloads';
}

Future<File> _defaultPageFetcher(
  String url,
  Map<String, String> headers,
) {
  return appImageCache.getSingleFile(url, headers: headers);
}

class DownloadScope extends InheritedNotifier<DownloadStore> {
  const DownloadScope({
    super.key,
    required DownloadStore store,
    required super.child,
  }) : super(notifier: store);

  static DownloadStore of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<DownloadScope>();
    assert(s != null, 'DownloadScope not found');
    return s!.notifier!;
  }

  static DownloadStore read(BuildContext context) {
    final s = context.getInheritedWidgetOfExactType<DownloadScope>();
    assert(s != null, 'DownloadScope not found');
    return s!.notifier!;
  }

  /// 不断言版:找不到返回 null(阅读器测试里可能没套 scope)。
  static DownloadStore? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DownloadScope>()?.notifier;
}
