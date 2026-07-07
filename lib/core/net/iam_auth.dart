import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// hertz-iam 账号登录客户端(直连授权 / Resource Owner Password Credentials）。
///
/// 用途:让 App 用 IAM 账号登录,拿到 access/refresh token,给 [HertzAccountBackend]
/// 调 `dreamreader-sync` 用。IAM 只管认证,数据存在自建的 dreamreader-sync。
///
/// token 端点:`POST {issuer}/realms/user/token`(form-urlencoded)
///   - grant_type=password:client_id/username/password/device_id
///   - grant_type=refresh_token:client_id/refresh_token
/// 响应:{ access_token, token_type:"Bearer", expires_in(秒), refresh_token }
///
/// 【前置】IAM 里要把 client(默认 `dreamreader`)注册为允许 password + refresh_token
/// 授权的 consumer,否则 password 登录会被拒(ErrGrantNotAllowed)。
///
/// token 存 [FlutterSecureStorage](Android Keystore / Windows DPAPI),不落明文 prefs。
class IamAuth {
  IamAuth._();
  static final IamAuth instance = IamAuth._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// IAM 基址(如 https://iam.example.com),末尾无斜杠。
  String issuer = '';

  /// 本 App 在 IAM 注册的 client_id(access token 的 audience)。
  String clientId = '';

  String? _accessToken;
  String? _refreshToken;
  int _expiresAtMs = 0;
  String? _username;
  String? _deviceId;

  bool get isLoggedIn => (_refreshToken?.isNotEmpty ?? false);
  String? get username => _username;

  static const _kAccess = 'iam.access';
  static const _kRefresh = 'iam.refresh';
  static const _kExpiresAt = 'iam.expiresAt';
  static const _kUsername = 'iam.username';
  static const _kDeviceId = 'iam.deviceId';

  /// 读回持久化的 token 与配置;首次生成稳定 device_id。
  Future<void> load({required String issuer, required String clientId}) async {
    configure(issuer: issuer, clientId: clientId);
    _accessToken = await _storage.read(key: _kAccess);
    _refreshToken = await _storage.read(key: _kRefresh);
    _expiresAtMs = int.tryParse(await _storage.read(key: _kExpiresAt) ?? '') ?? 0;
    _username = await _storage.read(key: _kUsername);
    _deviceId = await _storage.read(key: _kDeviceId);
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = _genDeviceId();
      await _storage.write(key: _kDeviceId, value: _deviceId);
    }
  }

  /// 只更新 issuer/clientId(用户在设置里改了地址时)。
  void configure({required String issuer, required String clientId}) {
    this.issuer = _normIssuer(issuer);
    this.clientId = clientId.trim();
  }

  String get _tokenUrl => '$issuer/realms/user/token';
  String get _userInfoUrl => '$issuer/realms/user/userinfo';

  Dio _dio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        // 4xx 我们自己读 msg;仅 5xx / 网络异常抛。
        validateStatus: (s) => s != null && s < 500,
      ));

  /// 用户名 + 密码登录。
  Future<void> loginPassword(String username, String password) async {
    _requireConfig();
    final r = await _dio().post<Map<String, dynamic>>(
      _tokenUrl,
      data: {
        'grant_type': 'password',
        'client_id': clientId,
        'username': username.trim(),
        'password': password,
        'device_id': _deviceId,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    await _consumeToken(r, fallbackUsername: username.trim());
  }

  /// 邮箱验证码登录(需先由 IAM 发码;当前 UI 未接,保留给后续)。
  Future<void> loginEmailCode(String email, String code) async {
    _requireConfig();
    final r = await _dio().post<Map<String, dynamic>>(
      _tokenUrl,
      data: {
        'grant_type': 'email_code',
        'client_id': clientId,
        'email': email.trim(),
        'verification_code': code.trim(),
        'device_id': _deviceId,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    await _consumeToken(r, fallbackUsername: email.trim());
  }

  /// 返回一个有效的 access token;过期(留 30s 余量)则用 refresh 换新;
  /// 未登录 / refresh 失效返回 null(此时 UI 应提示重新登录)。
  Future<String?> validAccessToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((_accessToken?.isNotEmpty ?? false) && now < _expiresAtMs - 30000) {
      return _accessToken;
    }
    if (_refreshToken == null || _refreshToken!.isEmpty) return null;
    try {
      final r = await _dio().post<Map<String, dynamic>>(
        _tokenUrl,
        data: {
          'grant_type': 'refresh_token',
          'client_id': clientId,
          'refresh_token': _refreshToken,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      if ((r.statusCode ?? 0) >= 400) {
        await logout(); // refresh 失效 → 需重新登录
        return null;
      }
      await _consumeToken(r, fallbackUsername: _username);
      return _accessToken;
    } catch (_) {
      return null;
    }
  }

  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAtMs = 0;
    _username = null;
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kExpiresAt);
    await _storage.delete(key: _kUsername);
    // device_id 保留(设备标识不必清)。
  }

  Future<void> _consumeToken(Response<Map<String, dynamic>> r,
      {String? fallbackUsername}) async {
    final s = r.statusCode ?? 0;
    final body = r.data ?? const <String, dynamic>{};
    if (s >= 400) {
      throw Exception((body['msg'] as String?) ?? _statusMsg(s));
    }
    final access = body['access_token'] as String?;
    final refresh = body['refresh_token'] as String?;
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 900;
    if (access == null || access.isEmpty) {
      throw Exception('登录响应缺少 access_token');
    }
    _accessToken = access;
    if (refresh != null && refresh.isNotEmpty) _refreshToken = refresh;
    _expiresAtMs = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    _username = fallbackUsername ?? _username;
    await _persist();
    unawaited(_fetchUserInfo()); // best-effort 拿真实用户名
  }

  Future<void> _fetchUserInfo() async {
    try {
      final r = await _dio().get<Map<String, dynamic>>(
        _userInfoUrl,
        options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
      );
      final name = r.data?['preferred_username'] as String?;
      if (name != null && name.isNotEmpty) {
        _username = name;
        await _storage.write(key: _kUsername, value: name);
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    await _storage.write(key: _kAccess, value: _accessToken);
    await _storage.write(key: _kRefresh, value: _refreshToken);
    await _storage.write(key: _kExpiresAt, value: '$_expiresAtMs');
    if (_username != null) {
      await _storage.write(key: _kUsername, value: _username);
    }
  }

  void _requireConfig() {
    if (issuer.isEmpty) throw Exception('未配置 IAM 地址');
    if (clientId.isEmpty) throw Exception('未配置 client_id');
  }

  static String _normIssuer(String u) {
    var s = u.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  String _genDeviceId() {
    // 稳定设备标识,仅供 IAM 区分设备会话,不需强随机。
    final r = Random();
    final hex = List<int>.generate(8, (_) => r.nextInt(256))
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'dmr-$hex';
  }

  static String _statusMsg(int s) {
    switch (s) {
      case 400:
        return '请求无效';
      case 401:
        return '账号或密码不对';
      case 403:
        return '该账号 / 客户端无权使用此登录方式';
      case 429:
        return '尝试过于频繁,请稍后再试';
      default:
        return '登录失败(HTTP $s)';
    }
  }
}
