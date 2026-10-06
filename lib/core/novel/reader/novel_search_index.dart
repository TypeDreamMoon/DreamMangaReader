import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'novel_render_document.dart';

/// 索引格式版本。改成 2 是因为每章多了一份块边界表（`.blocks.json`），
/// 旧索引里没有，得重建。
const int _manifestSchema = 2;

typedef NovelSearchRootDirectory = Future<Directory> Function();
typedef NovelSearchDocumentLoader = Future<NovelDocument?> Function(
  NovelChapter chapter,
);
typedef NovelSearchDocumentFetcher = Future<NovelDocument> Function(
  NovelChapter chapter,
);

String novelSearchSourceFingerprint(List<NovelChapter> chapters) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          for (final chapter in chapters)
            [
              chapter.id,
              chapter.title,
              chapter.number,
              chapter.publishedAt,
            ],
        ]),
      ),
    )
    .toString();

sealed class NovelSearchEvent {
  const NovelSearchEvent();
}

class NovelSearchProgress extends NovelSearchEvent {
  const NovelSearchProgress({
    required this.processedChapters,
    required this.totalChapters,
    required this.fetchedChapters,
  });

  final int processedChapters;
  final int totalChapters;
  final int fetchedChapters;

  double get fraction => totalChapters == 0
      ? 1
      : (processedChapters / totalChapters).clamp(0.0, 1.0);
}

class NovelSearchResultBatch extends NovelSearchEvent {
  const NovelSearchResultBatch(this.results);

  final List<NovelSearchResult> results;
}

class NovelSearchCompleted extends NovelSearchEvent {
  const NovelSearchCompleted({required this.resultCount});

  final int resultCount;
}

class NovelSearchCancelled extends NovelSearchEvent {
  const NovelSearchCancelled();
}

class NovelSearchResult {
  const NovelSearchResult({
    required this.chapterId,
    required this.chapterTitle,
    required this.chapterIndex,
    required this.snippet,
    required this.locator,
  });

  final String chapterId;
  final String chapterTitle;
  final int chapterIndex;
  final String snippet;
  final NovelLocator locator;
}

class NovelSearchCancellationToken {
  bool _cancelled = false;
  final Set<VoidCallback> _listeners = {};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
  }

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    if (_cancelled) listener();
  }

  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

typedef VoidCallback = void Function();

class NovelSearchIndex {
  NovelSearchIndex({NovelSearchRootDirectory? rootDirectory})
      : _rootDirectory = rootDirectory ?? _defaultRootDirectory;

  final NovelSearchRootDirectory _rootDirectory;

  static Future<Directory> _defaultRootDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
      '${support.path}${Platform.pathSeparator}novel_search_index',
    );
  }

  Future<Directory> directoryForBook(String bookKey) async {
    final root = await _rootDirectory();
    final digest = sha256.convert(utf8.encode(bookKey)).toString();
    final directory = Directory('${root.path}${Platform.pathSeparator}$digest');
    await directory.create(recursive: true);
    return directory;
  }

  Stream<NovelSearchEvent> search({
    required String bookKey,
    required String sourceFingerprint,
    required List<NovelChapter> chapters,
    required String query,
    required NovelSearchDocumentLoader loadCachedDocument,
    NovelSearchDocumentFetcher? fetchDocument,
    bool fetchMissing = false,
    NovelSearchCancellationToken? cancellation,
  }) async* {
    final normalizedQuery = _normalizeText(query).trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      yield const NovelSearchCompleted(resultCount: 0);
      return;
    }
    final token = cancellation ?? NovelSearchCancellationToken();
    if (token.isCancelled) {
      yield const NovelSearchCancelled();
      return;
    }
    final directory = await directoryForBook(bookKey);
    final manifestFile = File(
      '${directory.path}${Platform.pathSeparator}manifest.json',
    );
    final previous = await _readManifest(
      manifestFile,
      bookKey,
      sourceFingerprint,
    );
    final previousChapters = _manifestChapters(previous);
    final entries = <Map<String, Object?>>[];
    var fetched = 0;

    for (var chapterIndex = 0; chapterIndex < chapters.length; chapterIndex++) {
      if (token.isCancelled) {
        yield const NovelSearchCancelled();
        return;
      }
      final chapter = chapters[chapterIndex];
      NovelDocument? document = await loadCachedDocument(chapter);
      if (document == null && fetchMissing && fetchDocument != null) {
        document = await fetchDocument(chapter);
        fetched++;
      }
      final digest = '${sha256.convert(utf8.encode(chapter.id))}';
      final filename = '$digest.txt';
      final blocksFilename = '$digest.blocks.json';
      final file = File('${directory.path}${Platform.pathSeparator}$filename');
      final blocksFile = File(
        '${directory.path}${Platform.pathSeparator}$blocksFilename',
      );
      Map<String, Object?>? entry;
      if (document != null) {
        final indexed = novelSearchChapterText(document);
        final hash = sha256.convert(utf8.encode(indexed.text)).toString();
        final old = previousChapters[chapter.id];
        if (old?['hash'] != hash ||
            !await file.exists() ||
            !await blocksFile.exists()) {
          await _atomicWrite(file, indexed.text);
          await _atomicWrite(blocksFile, jsonEncode(indexed.blocks));
        }
        entry = {
          'id': chapter.id,
          'title': chapter.title,
          'index': chapterIndex,
          'hash': hash,
          'file': filename,
          'blocks': blocksFilename,
        };
      } else {
        final old = previousChapters[chapter.id];
        if (old != null) {
          final oldFilename = old['file'];
          if (oldFilename is String && _safeIndexFilename(oldFilename)) {
            final oldFile = File(
              '${directory.path}${Platform.pathSeparator}$oldFilename',
            );
            if (await oldFile.exists()) {
              entry = {
                ...old,
                'title': chapter.title,
                'index': chapterIndex,
              };
            }
          }
        }
      }
      if (entry != null) entries.add(entry);
      yield NovelSearchProgress(
        processedChapters: chapterIndex + 1,
        totalChapters: chapters.length,
        fetchedChapters: fetched,
      );
    }

    final retainedFiles = {
      ...entries.map((entry) => entry['file']).whereType<String>(),
      ...entries.map((entry) => entry['blocks']).whereType<String>(),
    };
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if ((name.endsWith('.txt') || name.endsWith('.blocks.json')) &&
          !retainedFiles.contains(name)) {
        await entity.delete();
      }
    }
    await _atomicWrite(
      manifestFile,
      jsonEncode({
        'schema': _manifestSchema,
        'bookKey': bookKey,
        'sourceFingerprint': sourceFingerprint,
        'chapters': entries,
      }),
    );

    if (token.isCancelled) {
      yield const NovelSearchCancelled();
      return;
    }
    yield* _scanInWorker(
      directory: directory,
      entries: entries,
      query: normalizedQuery,
      cancellation: token,
      fetchedChapters: fetched,
    );
  }

  Stream<NovelSearchEvent> _scanInWorker({
    required Directory directory,
    required List<Map<String, Object?>> entries,
    required String query,
    required NovelSearchCancellationToken cancellation,
    required int fetchedChapters,
  }) async* {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(
      _novelSearchWorker,
      {
        'sendPort': receive.sendPort,
        'directory': directory.path,
        'entries': entries,
        'query': query,
      },
      errorsAreFatal: true,
    );
    SendPort? control;
    var terminal = false;
    void requestCancellation() => control?.send('cancel');
    cancellation.addListener(requestCancellation);
    try {
      await for (final message in receive) {
        if (message is! Map) continue;
        final map = message.cast<String, dynamic>();
        switch (map['type']) {
          case 'ready':
            control = map['control'] as SendPort?;
            if (cancellation.isCancelled) control?.send('cancel');
          case 'batch':
            final raw = map['results'];
            if (raw is List) {
              yield NovelSearchResultBatch(
                raw
                    .whereType<Map>()
                    .map(
                      (value) => _resultFromMap(
                        value.cast<String, dynamic>(),
                      ),
                    )
                    .toList(growable: false),
              );
            }
          case 'progress':
            yield NovelSearchProgress(
              processedChapters: (map['processed'] as num?)?.toInt() ?? 0,
              totalChapters: entries.length,
              fetchedChapters: fetchedChapters,
            );
          case 'cancelled':
            terminal = true;
            yield const NovelSearchCancelled();
          case 'complete':
            terminal = true;
            yield NovelSearchCompleted(
              resultCount: (map['resultCount'] as num?)?.toInt() ?? 0,
            );
          case 'error':
            terminal = true;
            throw StateError(map['message']?.toString() ?? 'Search failed.');
        }
        if (terminal) break;
      }
    } finally {
      cancellation.removeListener(requestCancellation);
      receive.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

Future<void> _novelSearchWorker(Map<String, Object?> message) async {
  final sendPort = message['sendPort'] as SendPort;
  final directory = message['directory'] as String;
  final query = message['query'] as String;
  final entries = (message['entries'] as List)
      .whereType<Map>()
      .map((entry) => entry.cast<String, dynamic>())
      .toList(growable: false);
  final control = ReceivePort();
  var cancelled = false;
  control.listen((value) {
    if (value == 'cancel') cancelled = true;
  });
  sendPort.send({'type': 'ready', 'control': control.sendPort});
  try {
    var resultCount = 0;
    for (var chapterIndex = 0; chapterIndex < entries.length; chapterIndex++) {
      await Future<void>.delayed(Duration.zero);
      if (cancelled) {
        sendPort.send({'type': 'cancelled'});
        return;
      }
      final entry = entries[chapterIndex];
      final filename = entry['file'] as String;
      final text = await File(
        '$directory${Platform.pathSeparator}$filename',
      ).readAsString(encoding: utf8);
      final blocks = await _readBlockTable(directory, entry['blocks']);
      final searchText = text.toLowerCase();
      final results = <Map<String, Object?>>[];
      var from = 0;
      while (results.length < 200) {
        final index = searchText.indexOf(query, from);
        if (index < 0) break;
        final beforeStart = (index - 28).clamp(0, text.length);
        final afterEnd = (index + query.length + 48).clamp(0, text.length);
        // 定位到具体的块：没有 blockId 的 locator 会让 pageIndexForLocator 退化成按
        // 比例估算，含标题/空行的章节一估就偏好几页。
        final block = _blockAt(blocks, index);
        results.add({
          'chapterId': entry['id'],
          'chapterTitle': entry['title'],
          'chapterIndex': entry['index'],
          'blockId': block?.id,
          'charOffset': block == null ? index : index - block.start,
          'snippet': text.substring(beforeStart, afterEnd),
          'quote': text.substring(index, index + query.length),
          'prefix': text.substring(beforeStart, index),
          'suffix': text.substring(index + query.length, afterEnd),
          'fraction': text.isEmpty ? 0.0 : index / text.length,
        });
        from = index + query.length;
      }
      if (results.isNotEmpty) {
        resultCount += results.length;
        sendPort.send({'type': 'batch', 'results': results});
      }
      sendPort.send({'type': 'progress', 'processed': chapterIndex + 1});
    }
    sendPort.send({'type': 'complete', 'resultCount': resultCount});
  } catch (error) {
    sendPort.send({'type': 'error', 'message': error.toString()});
  } finally {
    control.close();
  }
}

NovelSearchResult _resultFromMap(Map<String, dynamic> value) {
  final chapterId = value['chapterId'] as String;
  return NovelSearchResult(
    chapterId: chapterId,
    chapterTitle: value['chapterTitle'] as String,
    chapterIndex: (value['chapterIndex'] as num).toInt(),
    snippet: value['snippet'] as String,
    locator: NovelLocator(
      chapterId: chapterId,
      blockId: value['blockId'] as String?,
      charOffset: (value['charOffset'] as num).toInt(),
      quote: value['quote'] as String,
      prefix: value['prefix'] as String,
      suffix: value['suffix'] as String,
      fraction: (value['fraction'] as num).toDouble(),
    ),
  );
}

/// 一章的可搜索正文，以及它是怎么由排版块拼起来的。
class NovelSearchChapterText {
  const NovelSearchChapterText(this.text, this.blocks);

  final String text;

  /// 每项是 `[blockId, start, length]`：start 是块在 [text] 里的起点。
  final List<List<Object?>> blocks;
}

/// 把文档展开成「正文 + 块边界」。
///
/// 与 [NovelRenderDocument.plainText] 逐字一致，所以命中位置减去块起点就是
/// 块内偏移 —— 与 [NovelPageFragment.sourceStart] 同一坐标系，分页器才能拿它定到页。
NovelSearchChapterText novelSearchChapterText(NovelDocument document) {
  final render = NovelRenderDocumentParser.parse(document);
  final buffer = StringBuffer();
  final blocks = <List<Object?>>[];
  for (final block in render.blocks) {
    final text = block.plainText;
    if (buffer.isNotEmpty) buffer.write('\n');
    if (text.isNotEmpty) {
      blocks.add([block.id, buffer.length, text.length]);
    }
    buffer.write(text);
  }
  return NovelSearchChapterText(buffer.toString(), blocks);
}

/// 只用来规范化查询词：正文侧不能动，动了偏移就对不上块边界了。
String _normalizeText(String value) => value
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll(RegExp(r'[\t\f\v ]+'), ' ')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

class _IndexedBlock {
  const _IndexedBlock(this.id, this.start, this.length);

  final String id;
  final int start;
  final int length;
}

Future<List<_IndexedBlock>> _readBlockTable(
  String directory,
  Object? filename,
) async {
  if (filename is! String || !_safeBlockFilename(filename)) return const [];
  try {
    final file = File('$directory${Platform.pathSeparator}$filename');
    if (!await file.exists()) return const [];
    final value = jsonDecode(await file.readAsString(encoding: utf8));
    if (value is! List) return const [];
    return [
      for (final entry in value.whereType<List>())
        if (entry.length == 3 && entry[0] is String)
          _IndexedBlock(
            entry[0] as String,
            (entry[1] as num).toInt(),
            (entry[2] as num).toInt(),
          ),
    ];
  } catch (_) {
    return const [];
  }
}

_IndexedBlock? _blockAt(List<_IndexedBlock> blocks, int offset) {
  var low = 0;
  var high = blocks.length - 1;
  while (low <= high) {
    final middle = (low + high) ~/ 2;
    final block = blocks[middle];
    if (offset < block.start) {
      high = middle - 1;
    } else if (offset >= block.start + block.length) {
      low = middle + 1;
    } else {
      return block;
    }
  }
  return null;
}

Future<Map<String, dynamic>> _readManifest(
  File file,
  String bookKey,
  String sourceFingerprint,
) async {
  try {
    if (!await file.exists()) return const {};
    final value = jsonDecode(await file.readAsString(encoding: utf8));
    if (value is! Map) return const {};
    final manifest = value.cast<String, dynamic>();
    // sourceFingerprint 以前只写不比：正文在线更新以后，搜索会一直沿用旧索引。
    return manifest['schema'] == _manifestSchema &&
            manifest['bookKey'] == bookKey &&
            manifest['sourceFingerprint'] == sourceFingerprint
        ? manifest
        : const {};
  } catch (_) {
    return const {};
  }
}

Map<String, Map<String, Object?>> _manifestChapters(
  Map<String, dynamic> manifest,
) {
  final raw = manifest['chapters'];
  if (raw is! List) return const {};
  return {
    for (final value in raw.whereType<Map>())
      if (value['id'] is String)
        value['id'] as String: value.cast<String, Object?>(),
  };
}

Future<void> _atomicWrite(File destination, String contents) async {
  final temporary = File('${destination.path}.tmp');
  final backup = File('${destination.path}.bak');
  await temporary.writeAsString(contents, encoding: utf8, flush: true);
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

String _basename(String path) => path.split(Platform.pathSeparator).last;

bool _safeIndexFilename(String value) =>
    RegExp(r'^[a-f0-9]{64}\.txt$').hasMatch(value);

bool _safeBlockFilename(String value) =>
    RegExp(r'^[a-f0-9]{64}\.blocks\.json$').hasMatch(value);
