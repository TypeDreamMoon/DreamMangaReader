import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';

import '../models.dart';

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
    final previous = await _readManifest(manifestFile, bookKey);
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
      final filename = '${sha256.convert(utf8.encode(chapter.id))}.txt';
      final file = File('${directory.path}${Platform.pathSeparator}$filename');
      Map<String, Object?>? entry;
      if (document != null) {
        final text = _documentText(document);
        final hash = sha256.convert(utf8.encode(text)).toString();
        final old = previousChapters[chapter.id];
        if (old?['hash'] != hash || !await file.exists()) {
          await _atomicWrite(file, text);
        }
        entry = {
          'id': chapter.id,
          'title': chapter.title,
          'index': chapterIndex,
          'hash': hash,
          'file': filename,
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

    final retainedFiles =
        entries.map((entry) => entry['file']).whereType<String>().toSet();
    for (final entity in directory.listSync()) {
      if (entity is File &&
          entity.path.endsWith('.txt') &&
          !retainedFiles.contains(_basename(entity.path))) {
        await entity.delete();
      }
    }
    await _atomicWrite(
      manifestFile,
      jsonEncode({
        'schema': 1,
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
      final searchText = text.toLowerCase();
      final results = <Map<String, Object?>>[];
      var from = 0;
      while (results.length < 200) {
        final index = searchText.indexOf(query, from);
        if (index < 0) break;
        final beforeStart = (index - 28).clamp(0, text.length);
        final afterEnd = (index + query.length + 48).clamp(0, text.length);
        results.add({
          'chapterId': entry['id'],
          'chapterTitle': entry['title'],
          'chapterIndex': entry['index'],
          'charOffset': index,
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
      charOffset: (value['charOffset'] as num).toInt(),
      quote: value['quote'] as String,
      prefix: value['prefix'] as String,
      suffix: value['suffix'] as String,
      fraction: (value['fraction'] as num).toDouble(),
    ),
  );
}

String _documentText(NovelDocument document) {
  if (document.format == NovelDocumentFormat.text) {
    return _normalizeText(document.content);
  }
  final fragment = html_parser.parseFragment(document.content);
  return _normalizeText(fragment.text ?? '');
}

String _normalizeText(String value) => value
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll(RegExp(r'[\t\f\v ]+'), ' ')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

Future<Map<String, dynamic>> _readManifest(File file, String bookKey) async {
  try {
    if (!await file.exists()) return const {};
    final value = jsonDecode(await file.readAsString(encoding: utf8));
    if (value is! Map) return const {};
    final manifest = value.cast<String, dynamic>();
    return manifest['schema'] == 1 && manifest['bookKey'] == bookKey
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
