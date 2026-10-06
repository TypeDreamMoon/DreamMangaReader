import 'dart:convert';

import 'package:dio/dio.dart';

import 'sync_backend.dart';
import 'sync_messages.dart';

/// WebDAV 同步后端:把同步 blob 存成远端一个 JSON 文件(`DreamMangaReader/sync.json`)。
/// 只用到 WebDAV 的 MKCOL(建目录)+ PUT(写)+ GET(读),Basic 认证。兼容 坚果云/Nextcloud/
/// Apache mod_dav 等。走 App 已注入的全局代理(dio 跟随 HttpOverrides)。
///
/// 并发控制走 ETag,和账号后端同一套语义:[pull] 记下远端版本,[push] 带
/// `If-Match` 推;服务器回 412 说明这中间别的设备写过,重新拉一份当作
/// [SyncConflict] 抛出去,由上层重合并后再推(见 `SyncController.syncNow`)。
/// 一个后端实例只在一次同步里复用,所以 [_etag] 用实例字段即可。
class WebDavBackend implements SyncBackend {
  WebDavBackend({
    required String baseUrl,
    required this.username,
    required this.password,
    this.adapter,
  }) : baseUrl = baseUrl.trim().endsWith('/') ? baseUrl.trim() : '${baseUrl.trim()}/';

  final String baseUrl;
  final String username;
  final String password;

  /// 测试用的替身适配器(生产环境不传,走 dio 默认的 HTTP 实现)。
  final HttpClientAdapter? adapter;

  /// 上次 [pull] 看到的远端版本;null = 不知道(没拉过 / 服务器不给 ETag)。
  String? _etag;

  static const _subdir = 'DreamMangaReader';
  static const _file = 'sync.json';

  String get _dirUrl => '$baseUrl$_subdir/';
  String get _fileUrl => '$baseUrl$_subdir/$_file';

  Dio _client() {
    final auth = base64Encode(utf8.encode('$username:$password'));
    final dio = Dio(BaseOptions(
      headers: {'Authorization': 'Basic $auth'},
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      followRedirects: true,
      // 4xx 我们自己判(401=认证错、404=还没同步过、412=并发冲突);仅 5xx / 网络异常抛。
      validateStatus: (s) => s != null && s < 500,
    ));
    final stub = adapter;
    if (stub != null) dio.httpClientAdapter = stub;
    return dio;
  }

  /// 建同步目录(已存在返回 405,无所谓)。401/403 抛,让上层报「认证/权限」。
  Future<void> _ensureDir(Dio dio) async {
    final r = await dio.request<void>(_dirUrl, options: Options(method: 'MKCOL'));
    final s = r.statusCode ?? 0;
    if (s == 401 || s == 403) {
      throw SyncException.of(
          s == 401 ? SyncMessage.authFailed : SyncMessage.forbidden,
          httpStatus: s);
    }
  }

  /// 测试连通 + 认证:MKCOL 同步目录。201=新建、405/301=已存在 → 都算通;401/403=认证/权限错。
  @override
  Future<SyncTestResult> test() async {
    try {
      final dio = _client();
      final r = await dio.request<void>(_dirUrl, options: Options(method: 'MKCOL'));
      final s = r.statusCode ?? 0;
      if (s == 401) {
        return SyncTestResult.failure(SyncMessage.authFailed, httpStatus: s);
      }
      if (s == 403) {
        return SyncTestResult.failure(SyncMessage.forbidden, httpStatus: s);
      }
      if (s == 201 || s == 405 || s == 301 || s == 200) {
        return SyncTestResult.success(SyncMessage.testWebDavReady);
      }
      return SyncTestResult.failure(SyncMessage.unexpectedStatus,
          httpStatus: s);
    } catch (e) {
      return SyncTestResult.failure(SyncMessage.unreachable, detail: '$e');
    }
  }

  /// 拉远端 blob;还没同步过(404 / 空)返回 null。顺带记下 ETag 供 [push] 用。
  @override
  Future<Map<String, dynamic>?> pull() async {
    final dio = _client();
    final r = await dio.get<String>(_fileUrl,
        options: Options(responseType: ResponseType.plain));
    final s = r.statusCode ?? 0;
    if (s == 404) {
      _etag = null;
      return null;
    }
    if (s == 401 || s == 403) {
      throw SyncException.of(
          s == 401 ? SyncMessage.authFailed : SyncMessage.forbidden,
          httpStatus: s);
    }
    if (s >= 400) {
      throw SyncException.of(SyncMessage.pullFailed, httpStatus: s);
    }
    _etag = _strongEtag(r.headers.value('etag'));
    final body = (r.data ?? '').trim();
    if (body.isEmpty) return null;
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// 推 blob 到远端。带 `If-Match` 做乐观并发:412 = 拉完之后远端被别的设备改过,
  /// 重新拉一份当 [SyncConflict] 抛出,由上层重合并后重试。
  ///
  /// 之前这里是无条件覆盖:A 和 B 同时同步,后写的一方把先写的那份整个抹掉,
  /// 用户表现为「刚在另一台加的收藏又没了」。
  @override
  Future<void> push(Map<String, dynamic> blob) async {
    final dio = _client();
    await _ensureDir(dio);
    final body = const JsonEncoder.withIndent('  ').convert(blob);
    final etag = _etag;
    final r = await dio.put<void>(
      _fileUrl,
      data: body,
      options: Options(
        contentType: 'application/json',
        headers: etag == null ? null : <String, dynamic>{'If-Match': etag},
      ),
    );
    final s = r.statusCode ?? 0;
    if (s == 412) {
      // 重新 pull 会顺带把 _etag 更新到最新版本,重试的那次 push 才推得上去。
      throw SyncConflict(await pull());
    }
    if (s >= 400) {
      throw SyncException.of(SyncMessage.pushFailed, httpStatus: s);
    }
    // PUT 回的 ETag 是新版本;服务器不给就把记录清掉——宁可下一次退回无条件
    // 覆盖,也不能拿旧版本号去 If-Match(那会 412 到死)。
    _etag = _strongEtag(r.headers.value('etag'));
  }

  /// 只接受强 ETag。`W/"..."` 是弱验证器,RFC 9110 不允许用于 `If-Match`,
  /// 拿它当条件的结果因服务器而异,不如当作「没有版本号」。
  static String? _strongEtag(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty || value.startsWith('W/')) return null;
    return value;
  }
}
