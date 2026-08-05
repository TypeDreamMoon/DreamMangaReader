import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
  NovelLibraryStore novels,
) =>
    sanitizeBackupData({
      ...store.exportData(),
      'novels': novels.exportData(),
    });

Map<String, dynamic> sanitizeBackupData(Map<String, dynamic> data) =>
    _sanitizePortableValue(data) as Map<String, dynamic>;

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

bool _isDeviceSecretKey(String key) =>
    key == 'sources.token' ||
    key == 'source.repository.token' ||
    (key.startsWith('auth.') && key.endsWith('.token'));

Future<void> restoreBackupData(
  LibraryStore store,
  NovelLibraryStore novels,
  Map<String, dynamic> data,
) async {
  final portable = sanitizeBackupData(data);
  await store.importData(portable);
  final novelData = portable['novels'];
  if (novelData is Map) {
    await novels.importData(novelData.cast<String, dynamic>());
  }
}

Future<String> exportBackup(
  LibraryStore store,
  NovelLibraryStore novels,
) async {
  final path = await backupPath();
  await File(path).writeAsString(const JsonEncoder.withIndent('  ')
      .convert(buildBackupData(store, novels)));
  return path;
}

/// 从备份文件恢复。文件不存在返回 false。
Future<bool> importBackup(
  LibraryStore store,
  NovelLibraryStore novels,
) async {
  final file = File(await backupPath());
  if (!file.existsSync()) return false;
  final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  await restoreBackupData(store, novels, data);
  return true;
}
