import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'library_store.dart';

/// 备份文件的固定路径(用户可自行拷走/放回来做异地备份)。
Future<String> backupPath() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/DreamMangaReader_backup.json';
}

/// 导出书架(收藏 + 阅读进度 + 阅读设置)到备份文件,返回路径。
Future<String> exportBackup(LibraryStore store) async {
  final path = await backupPath();
  await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(store.exportData()));
  return path;
}

/// 从备份文件恢复。文件不存在返回 false。
Future<bool> importBackup(LibraryStore store) async {
  final file = File(await backupPath());
  if (!file.existsSync()) return false;
  final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  await store.importData(data);
  return true;
}
