import 'dart:convert';

import 'package:dio/dio.dart';

import 'sync_backend.dart';

/// WebDAV 同步后端:把同步 blob 存成远端一个 JSON 文件(`DreamMangaReader/sync.json`)。
/// 只用到 WebDAV 的 MKCOL(建目录)+ PUT(写)+ GET(读),Basic 认证。兼容 坚果云/Nextcloud/
/// Apache mod_dav 等。走 App 已注入的全局代理(dio 跟随 HttpOverrides)。
class WebDavBackend implements SyncBackend {
  WebDavBackend({
    required String baseUrl,
    required this.username,
    required this.password,
  }) : baseUrl = baseUrl.trim().endsWith('/') ? baseUrl.trim() : '${baseUrl.trim()}/';

  final String baseUrl;
  final String username;
  final String password;

  static const _subdir = 'DreamMangaReader';
  static const _file = 'sync.json';

  String get _dirUrl => '$baseUrl$_subdir/';
  String get _fileUrl => '$baseUrl$_subdir/$_file';

  Dio _client() {
    final auth = base64Encode(utf8.encode('$username:$password'));
    return Dio(BaseOptions(
      headers: {'Authorization': 'Basic $auth'},
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      followRedirects: true,
      // 4xx 我们自己判(401=认证错、404=还没同步过);仅 5xx / 网络异常抛。
      validateStatus: (s) => s != null && s < 500,
    ));
  }

  /// 建同步目录(已存在返回 405,无所谓)。401/403 抛,让上层报「认证/权限」。
  Future<void> _ensureDir(Dio dio) async {
    final r = await dio.request<void>(_dirUrl, options: Options(method: 'MKCOL'));
    final s = r.statusCode ?? 0;
    if (s == 401 || s == 403) {
      throw Exception('WebDAV 认证/权限失败(HTTP $s)');
    }
  }

  /// 测试连通 + 认证:MKCOL 同步目录。201=新建、405/301=已存在 → 都算通;401/403=认证/权限错。
  @override
  Future<(bool, String)> test() async {
    try {
      final dio = _client();
      final r = await dio.request<void>(_dirUrl, options: Options(method: 'MKCOL'));
      final s = r.statusCode ?? 0;
      if (s == 401) return (false, '认证失败:账号或密码不对(HTTP 401)');
      if (s == 403) return (false, '权限不足:该账号不能建目录(HTTP 403)');
      if (s == 201 || s == 405 || s == 301 || s == 200) {
        return (true, '连接成功 · 同步目录就绪');
      }
      return (false, '异常响应 HTTP $s');
    } catch (e) {
      return (false, '连不上:$e');
    }
  }

  /// 拉远端 blob;还没同步过(404 / 空)返回 null。
  @override
  Future<Map<String, dynamic>?> pull() async {
    final dio = _client();
    final r = await dio.get<String>(_fileUrl,
        options: Options(responseType: ResponseType.plain));
    final s = r.statusCode ?? 0;
    if (s == 404 || (r.data ?? '').trim().isEmpty) return null;
    if (s == 401 || s == 403) throw Exception('WebDAV 认证/权限失败(HTTP $s)');
    if (s >= 400) throw Exception('WebDAV 拉取失败(HTTP $s)');
    return jsonDecode(r.data!) as Map<String, dynamic>;
  }

  /// 推 blob 到远端(覆盖)。
  @override
  Future<void> push(Map<String, dynamic> blob) async {
    final dio = _client();
    await _ensureDir(dio);
    final body = const JsonEncoder.withIndent('  ').convert(blob);
    final r = await dio.put<void>(_fileUrl,
        data: body, options: Options(contentType: 'application/json'));
    final s = r.statusCode ?? 0;
    if (s >= 400) throw Exception('WebDAV 上传失败(HTTP $s)');
  }
}
