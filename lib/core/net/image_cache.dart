import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../log/app_log.dart';
import 'app_proxy.dart';
import 'url_redaction.dart';

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
    fileService: appImageFileService,
  ),
);

/// 图片下载用的 FileService。单独暴露出来只为可测:它得在代理改动后换掉底层 client。
final ProxyAwareImageService appImageFileService = ProxyAwareImageService();

/// 图片拉取加一层运行日志(排查「封面加载不出来」):非 2xx 记警告、连不上/超时
/// 记错误,带**脱敏后**的 URL 和 Referer;成功不记(封面+章节图量大,会刷屏)。
///
/// 图源地址常带防盗链签名(`token`/`sign`/`X-Amz-Signature`…),Referer 也可能带;
/// 日志页能整份复制发出去,所以两者都得先过 [redactUrlCredentials]。
///
/// 另一件事是跟住代理:[HttpFileService] 在构造时就建好 `http.Client`(底下是一个
/// `dart:io HttpClient`),而 `HttpClient` 只在**构造那一刻**读 [HttpOverrides.global]。
/// 这个 service 是全局单例、只建一次,于是用户在设置页改完代理,封面和章节图还在走
/// 旧代理(或旧的直连),直到重启 App 才对——所以按 [AppProxy.generation] 换代。
class ProxyAwareImageService extends FileService {
  ProxyAwareImageService({FileService Function()? createDelegate})
      : _createDelegate = createDelegate ?? HttpFileService.new;

  final FileService Function() _createDelegate;
  FileService? _delegate;
  int _generation = -1;

  /// 当前代理世代下的下载器;代理变了就换一个新的(连同它内部的 HttpClient)。
  FileService get _service {
    final generation = AppProxy.generation;
    final current = _delegate;
    if (current != null && _generation == generation) return current;
    _generation = generation;
    return _delegate = _createDelegate();
  }

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final sw = Stopwatch()..start();
    try {
      final r = await _service.get(url, headers: headers);
      final code = r.statusCode;
      // 304 = 缓存重验证命中(If-None-Match),是成功路径,不算失败。
      if ((code < 200 || code >= 300) && code != 304) {
        AppLog.i.warn(LogCat.network,
            'IMG ${shortUrl(url)} · $code · ${sw.elapsedMilliseconds}ms',
            detail: _detail(url, headers));
      }
      return r;
    } catch (e) {
      AppLog.i.err(LogCat.network,
          'IMG ${shortUrl(url)} · 失败 · ${sw.elapsedMilliseconds}ms',
          detail: '${_detail(url, headers)}\n${redactUrlCredentials('$e')}');
      rethrow;
    }
  }

  static String _detail(String url, Map<String, String>? headers) {
    final referer = headers?['Referer'];
    final shown = (referer == null || referer.isEmpty)
        ? '(无)'
        : redactUrlCredentials(referer);
    return '${redactUrlCredentials(url)}\nReferer: $shown';
  }
}

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
