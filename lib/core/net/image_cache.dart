import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

/// 全 App 共用的图片磁盘缓存管理器(封面 + 章节页共用)。
///
/// 关键:用纯 Dart 的 [JsonCacheInfoRepository] 存缓存元数据,**绕开 sqflite**——
/// flutter_cache_manager 默认的 CacheObjectProvider 依赖 sqflite,而 Windows 桌面
/// 没有 sqflite 实现,默认配置会在运行时崩。JSON 仓库在所有平台都能用。
///
/// 自定义请求头(防盗链 Referer / UA)在使用处经 `httpHeaders` 传入,不在这里配。
final CacheManager appImageCache = CacheManager(
  Config(
    _cacheKey,
    stalePeriod: const Duration(days: 14),
    maxNrOfCacheObjects: 800,
    repo: JsonCacheInfoRepository(databaseName: _cacheKey),
    fileService: HttpFileService(),
  ),
);

const String _cacheKey = 'dmr_images';

/// 清空图片磁盘缓存(设置页「清理缓存」用)。
Future<void> clearImageCache() => appImageCache.emptyCache();

/// 图片缓存(封面 + 章节图)占用的磁盘字节数。取不到则 0。
Future<int> imageCacheSizeBytes() async {
  try {
    final tmp = await getTemporaryDirectory();
    return dirSizeBytes(Directory('${tmp.path}/$_cacheKey'));
  } catch (_) {
    return 0;
  }
}

/// 递归统计目录字节数(缓存大小展示共用)。
Future<int> dirSizeBytes(Directory d) async {
  if (!await d.exists()) return 0;
  var total = 0;
  try {
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return total;
}
