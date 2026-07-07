import 'dart:convert';

import 'package:dio/dio.dart';

import '../net/iam_auth.dart';
import 'sync_backend.dart';

/// 自建账号同步后端:把同步 blob 存到 `dreamreader-sync` 服务(每用户一份)。
///
/// 鉴权走 [IamAuth](IAM 的 access token,Bearer)。并发控制走 ETag:
///   - [pull] GET /api/v1/sync → 记住 `data.etag`,返回 `data.doc`(null=还没同步过)。
///   - [push] PUT /api/v1/sync + `If-Match: <etag>`;
///       200 → 更新 etag;409 → 服务端已被其它设备更新,回传当前态 → 抛 [SyncConflict]。
///
/// 一个后端实例只在一次同步里复用(pull 记 etag → push 用),因此 [_etag] 用实例字段即可。
class HertzAccountBackend implements SyncBackend {
  HertzAccountBackend({required String baseUrl, required this.auth})
      : baseUrl = _norm(baseUrl);

  final String baseUrl;
  final IamAuth auth;

  String _etag = '';

  static String _norm(String u) {
    var s = u.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  String get _syncUrl => '$baseUrl/api/v1/sync';

  Dio _client(String token) => Dio(BaseOptions(
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
        // 4xx 自己判(401=过期、409=冲突);仅 5xx / 网络异常抛。
        validateStatus: (s) => s != null && s < 500,
      ));

  Future<String> _token() async {
    final t = await auth.validAccessToken();
    if (t == null) throw Exception('未登录账号(或登录已过期,请重新登录)');
    return t;
  }

  @override
  Future<(bool, String)> test() async {
    try {
      // 先探活(无需鉴权)。
      final health = await Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        validateStatus: (s) => s != null && s < 500,
      )).get<dynamic>('$baseUrl/healthz');
      if ((health.statusCode ?? 0) >= 400) {
        return (false, '同步服务无响应(HTTP ${health.statusCode})');
      }
      if (!auth.isLoggedIn) return (false, '服务在线,但还没登录账号');
      final token = await _token();
      final r = await _client(token).get<dynamic>(_syncUrl);
      final s = r.statusCode ?? 0;
      if (s == 401) return (false, '登录已过期,请重新登录');
      if (s >= 400) return (false, '异常响应 HTTP $s');
      return (true, '连接成功 · 账号已登录');
    } catch (e) {
      return (false, '连不上:$e');
    }
  }

  @override
  Future<Map<String, dynamic>?> pull() async {
    final token = await _token();
    final r = await _client(token).get<Map<String, dynamic>>(_syncUrl);
    final s = r.statusCode ?? 0;
    if (s == 401) throw Exception('登录已过期,请重新登录');
    if (s >= 400) throw Exception('拉取失败(HTTP $s)');
    final data = r.data?['data'] as Map<String, dynamic>?;
    _etag = (data?['etag'] as String?) ?? '';
    return _asBlob(data?['doc']);
  }

  @override
  Future<void> push(Map<String, dynamic> blob) async {
    final token = await _token();
    final headers = <String, dynamic>{};
    if (_etag.isNotEmpty) headers['If-Match'] = _etag;
    final r = await _client(token).put<Map<String, dynamic>>(
      _syncUrl,
      data: jsonEncode(blob),
      options: Options(contentType: 'application/json', headers: headers),
    );
    final s = r.statusCode ?? 0;
    if (s == 401) throw Exception('登录已过期,请重新登录');
    if (s == 409) {
      // 并发写入:服务端回传当前态 → 更新 etag,抛冲突让上层重合并重试。
      final data = r.data?['data'] as Map<String, dynamic>?;
      _etag = (data?['etag'] as String?) ?? _etag;
      throw SyncConflict(_asBlob(data?['doc']));
    }
    if (s >= 400) throw Exception('上传失败(HTTP $s)');
    final data = r.data?['data'] as Map<String, dynamic>?;
    _etag = (data?['etag'] as String?) ?? _etag;
  }

  /// 把服务端 `doc` 字段(可能是 null / Map)规整成 blob。
  static Map<String, dynamic>? _asBlob(Object? doc) {
    if (doc is Map<String, dynamic>) return doc;
    if (doc is Map) return doc.cast<String, dynamic>();
    return null;
  }
}
