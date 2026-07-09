import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log/app_log.dart';
import '../core/net/image_cache.dart';
import '../core/source/models.dart';
import '../core/source/source_registry.dart';

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

  static DownloadedChapter fromJson(Map<String, dynamic> j) => DownloadedChapter(
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
class DownloadStore extends ChangeNotifier {
  static const _kIndex = 'downloads.index';

  final Map<String, DownloadedChapter> _done = {};
  final Map<String, double> _progress = {}; // key → 0..1(进行中/排队)
  final List<_Job> _queue = [];
  bool _running = false;
  bool _disposed = false;

  SharedPreferences? _prefs;
  String? _root;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationSupportDirectory();
    _root = '${dir.path}/downloads';
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

  void enqueue(
      SourceMeta meta, Manga manga, Chapter chapter, Map<String, String> headers) {
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
    final key = job.key;
    final label = '《${job.manga.title}》${job.chapter.name}';
    final source = buildSource(job.meta);
    AppLog.i.info(LogCat.download, '开始下载 $label');
    try {
      final pages = await source.getPages(job.manga.id, job.chapter.id);
      if (pages.isEmpty) {
        AppLog.i.warn(LogCat.download, '$label:没有页面,跳过');
        _progress.remove(key);
        notifyListeners();
        return;
      }
      final dir = Directory(
          '$_root/${job.meta.id}/${_safe(job.manga.id)}/${_safe(job.chapter.id)}');
      await dir.create(recursive: true);
      for (var i = 0; i < pages.length; i++) {
        if (_disposed) return;
        final h = {...job.headers, ...?pages[i].headers};
        try {
          final f = await appImageCache.getSingleFile(pages[i].url, headers: h);
          await f.copy('${dir.path}/$i.img');
        } catch (_) {
          // 单页失败不整章中断,但记为不完整:直接放弃本章。
          AppLog.i.err(LogCat.download, '$label 第 ${i + 1} 页下载失败,已放弃本章');
          _progress.remove(key);
          notifyListeners();
          try {
            await dir.delete(recursive: true);
          } catch (_) {}
          return;
        }
        _progress[key] = (i + 1) / pages.length;
        notifyListeners();
      }
      _done[key] = DownloadedChapter(
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
      _progress.remove(key);
      _persist();
      notifyListeners();
      AppLog.i.success(LogCat.download, '下载完成 $label · ${pages.length} 页');
    } catch (e) {
      AppLog.i.err(LogCat.download, '$label 下载出错:$e');
      _progress.remove(key);
      notifyListeners();
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
    _persist();
    notifyListeners();
  }

  Future<void> deleteManga(String sourceId, String mangaId) async {
    final keys =
        _done.keys.where((k) => k.startsWith('$sourceId:$mangaId:')).toList();
    for (final k in keys) {
      await deleteChapter(k);
    }
  }

  void _persist() => _prefs?.setString(_kIndex,
      jsonEncode({for (final e in _done.entries) e.key: e.value.toJson()}));

  String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
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
