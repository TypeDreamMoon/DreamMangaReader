import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// 桌面(Windows/Linux)OAuth 回调的固定本机端口。IAM 需注册
/// `http://localhost:$kDesktopRedirectPort/` 为 redirect_uri。
const int kDesktopRedirectPort = 8765;

/// hertz-iam 账号登录客户端(浏览器 OAuth 授权码 + PKCE)。
///
/// 用途:让 App 用 IAM 账号登录,拿到 access/refresh token,给 [HertzAccountBackend]
/// 调 `dreamreader-sync` 用。IAM 只管认证,数据存在自建的 dreamreader-sync。
///
/// 登录:[loginBrowser] 打开系统浏览器授权 → 回调取 code → `POST {issuer}/realms/user/token`
/// (grant_type=authorization_code + code_verifier)换 token;之后用 refresh_token 续期。
/// 响应:{ access_token, token_type:"Bearer", expires_in(秒), refresh_token }。
///
/// 【前置】IAM 里 client(默认 `dreamreader`)需为 public、允许 authorization_code +
/// refresh_token、开 PKCE,并注册对应 redirect_uri(见 [loginBrowser])。
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
  String? _deviceId; // 稳定设备标识,password 授权带上供 IAM 区分会话

  bool get isLoggedIn => (_refreshToken?.isNotEmpty ?? false);
  String? get username => _username;

  static const _kAccess = 'iam.access';
  static const _kRefresh = 'iam.refresh';
  static const _kExpiresAt = 'iam.expiresAt';
  static const _kUsername = 'iam.username';
  static const _kDeviceId = 'iam.deviceId';

  /// 读回持久化的 token 与配置。
  Future<void> load({required String issuer, required String clientId}) async {
    configure(issuer: issuer, clientId: clientId);
    _accessToken = await _storage.read(key: _kAccess);
    _refreshToken = await _storage.read(key: _kRefresh);
    _expiresAtMs = int.tryParse(await _storage.read(key: _kExpiresAt) ?? '') ?? 0;
    _username = await _storage.read(key: _kUsername);
    _deviceId = await _storage.read(key: _kDeviceId);
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = 'dmr-${_randomUrlSafe(8)}';
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

  /// 用户名 + 密码登录(ROPC 直连授权)。用于 Custom 自建 IAM——免注册 redirect_uri、
  /// 免浏览器跳转。要求该 client 允许 `password` 授权。
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

  /// 浏览器 OAuth 登录(授权码 + PKCE)。
  ///
  /// 打开系统浏览器到 IAM 授权页,用户在浏览器里登录/授权 → IAM 回调到本机
  /// redirect_uri(Android 自定义 scheme;Windows/Linux localhost 回环)→ 取 code →
  /// 用 code_verifier 换 token。密码全程不经过 App。
  ///
  /// 【前置】IAM 里 client 需为 public、允许 authorization_code(+refresh_token)、开 PKCE,
  /// 并注册下列 redirect_uri:
  ///   - Android:`dreammangareader://auth`
  ///   - Windows/Linux:`http://localhost:$kDesktopRedirectPort/`
  Future<void> loginBrowser() async {
    _requireConfig();
    final verifier = _randomUrlSafe(64);
    final challenge = _s256(verifier);
    final state = _randomUrlSafe(24);
    final (callbackScheme, redirectUri) = _redirect();

    final authUrl = Uri.parse('$issuer/realms/user/authorize').replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'scope': 'openid',
      },
    ).toString();

    final result = await FlutterWebAuth2.authenticate(
      url: authUrl,
      callbackUrlScheme: callbackScheme,
      // 桌面强制走「系统浏览器 + localhost 回环」而非内嵌 webview:
      // flutter_web_auth_2 5.x 在 Windows/Linux 默认 useWebview=true(弹内嵌
      // Authenticate 窗口),我们要的是真·跳系统浏览器。Android 忽略此项(仍走 Custom Tabs)。
      options: const FlutterWebAuth2Options(useWebview: false),
    );

    final res = Uri.parse(result);
    final err = res.queryParameters['error'];
    if (err != null) {
      throw Exception('授权被拒绝:${res.queryParameters['error_description'] ?? err}');
    }
    if (res.queryParameters['state'] != state) {
      throw Exception('state 不匹配,已中止(可能被劫持)');
    }
    final code = res.queryParameters['code'];
    if (code == null || code.isEmpty) throw Exception('未拿到授权码');

    final r = await _dio().post<Map<String, dynamic>>(
      _tokenUrl,
      data: {
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'code': code,
        'redirect_uri': redirectUri,
        'code_verifier': verifier,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    await _consumeToken(r);
  }

  /// 按平台给出 (callbackUrlScheme, redirect_uri)。桌面用 localhost 回环(flutter_web_auth_2
  /// 限制回调必须是 http://localhost:{port});移动端用自定义 scheme。
  (String, String) _redirect() {
    if (Platform.isWindows || Platform.isLinux) {
      return (
        'http://localhost:$kDesktopRedirectPort',
        'http://localhost:$kDesktopRedirectPort/',
      );
    }
    return ('dreammangareader', 'dreammangareader://auth');
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

  /// URL-safe 随机串(用于 PKCE code_verifier 与 state),强随机。
  static String _randomUrlSafe(int bytes) {
    final r = Random.secure();
    final b = List<int>.generate(bytes, (_) => r.nextInt(256));
    return base64Url.encode(b).replaceAll('=', '');
  }

  /// PKCE S256:base64url(sha256(verifier)),去掉 padding。
  static String _s256(String verifier) {
    final digest = sha256.convert(ascii.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
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
