import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/novel/reader/novel_reader_data.dart';
import '../core/novel/reader/novel_reader_data_store.dart';
import 'library_store.dart';
import 'novel_library_store.dart';

/// 备份文件的固定路径(用户可自行拷走/放回来做异地备份)。
Future<String> backupPath() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/DreamMangaReader_backup.json';
}

/// 导出书架(收藏 + 阅读进度 + 阅读设置)到备份文件,返回路径。
Map<String, dynamic> buildBackupData(
  LibraryStore store,
  NovelLibraryStore novels, {
  Map<String, dynamic>? readerNotes,
}) {
  final novelData = novels.exportData();
  if (readerNotes != null) {
    novelData['readerNotes'] = sanitizePortableNovelReaderData(readerNotes);
  }
  return sanitizeBackupData({
    ...store.exportData(),
    'novels': novelData,
  });
}

Map<String, dynamic> sanitizeBackupData(Map<String, dynamic> data) {
  final sanitized =
      (_sanitizePortableValue(data) as Map).cast<String, dynamic>();
  final novels = sanitized['novels'];
  if (novels is Map && novels.containsKey('readerNotes')) {
    novels['readerNotes'] =
        sanitizePortableNovelReaderData(novels['readerNotes']);
  }
  return sanitized;
}

Object? _sanitizePortableValue(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        if (entry.key is String && !_isDeviceSecretKey(entry.key as String))
          entry.key as String: _sanitizePortableValue(entry.value),
    };
  }
  if (value is List) {
    return [for (final item in value) _sanitizePortableValue(item)];
  }
  return value;
}

bool _isDeviceSecretKey(String key) {
  final normalized = key.toLowerCase();
  return normalized == 'sources.token' ||
      normalized == 'source.repository.token' ||
      (normalized.startsWith('auth.') && normalized.endsWith('.token')) ||
      const {
        'chaptertext',
        'booktext',
        'fulltext',
        'searchindex',
        'privatepath',
        'localpath',
        'sourcetoken',
        'fontbytes',
        'backgroundbytes',
        'bgimage',
        'bgimagedata',
        'pagescreenshot',
      }.contains(normalized);
}

Future<void> restoreBackupData(
  LibraryStore store,
  NovelLibraryStore novels,
  Map<String, dynamic> data, {
  NovelReaderDataStore? readerDataStore,
  bool appendReaderNotes = false,
}) async {
  final portable = sanitizeBackupData(data);
  await store.importData(portable);
  final novelData = portable['novels'];
  if (novelData is Map) {
    await novels.importData(novelData.cast<String, dynamic>());
    if (novelData['readerNotes'] is Map) {
      await (readerDataStore ?? NovelReaderDataStore.instance)
          .importPortableData(
        novelData['readerNotes'],
        append: appendReaderNotes,
      );
    }
  }
}

Future<String> exportBackup(
  LibraryStore store,
  NovelLibraryStore novels, {
  NovelReaderDataStore? readerDataStore,
}) async {
  final path = await backupPath();
  final readerNotes = await (readerDataStore ?? NovelReaderDataStore.instance)
      .exportPortableData();
  await File(path).writeAsString(const JsonEncoder.withIndent('  ')
      .convert(buildBackupData(store, novels, readerNotes: readerNotes)));
  return path;
}

/// 从备份文件恢复。文件不存在返回 false。
Future<bool> importBackup(
  LibraryStore store,
  NovelLibraryStore novels, {
  NovelReaderDataStore? readerDataStore,
  bool appendReaderNotes = false,
}) async {
  final file = File(await backupPath());
  if (!file.existsSync()) return false;
  final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  await restoreBackupData(
    store,
    novels,
    data,
    readerDataStore: readerDataStore,
    appendReaderNotes: appendReaderNotes,
  );
  return true;
}
