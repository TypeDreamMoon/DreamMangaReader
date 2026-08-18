import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// hertz-iam 契约错误码。
///
/// 与服务端 `packages/contracts/errors/error_codes.yaml` 一一对应 —— 那份 yaml
/// 是 source of truth,这里只是抄一份能在 UI 里 switch 的常量。信封的 `code`
/// 字段是**稳定**的,HTTP 状态码不是,所以判定一律看它。
abstract final class IamErr {
  static const ok = 0;
  static const internal = 1;
  static const invalidRequest = 1001;
  static const unauthorized = 1002;
  static const forbidden = 1003;
  static const notFound = 1004;
  static const rateLimited = 1005;

  static const invalidCredentials = 2001;
  static const accountExists = 2002;
  static const accountInactive = 2003;
  static const weakPassword = 2004;
  static const invalidUsername = 2005;

  static const invalidToken = 3001;
  static const refreshReused = 3002;

  /// client_id 没在 IAM 注册,或该 consumer 被停用。
  static const unknownConsumer = 4001;

  /// consumer 存在,但 allowed_grants 里没有这次用的授权方式。
  static const invalidGrant = 4003;

  static const codeInvalid = 6001;
  static const codeCooldown = 6002;
  static const codeTooManyAttempts = 6003;
}

/// 发码场景。与服务端 `credential.Scene` 同名。
enum IamCodeScene {
  signup,
  login,
  reset;

  String get wire => name;
}

/// IAM 返回的业务错误。[code] 见 [IamErr];UI 据此出本地化文案,
/// 拿不到对应文案时退回服务端的 [serverMsg]。
///
/// [traceId] 是服务端给的排查线索,拼在文案末尾,用户截图报障时能直接对上日志。
class IamException implements Exception {
  IamException(this.code, this.serverMsg, {this.traceId});

  final int code;
  final String serverMsg;
  final String? traceId;

  @override
  String toString() =>
      'IamException($code): $serverMsg${traceId != null ? ' [$traceId]' : ''}';
}

/// hertz-iam 账号客户端(App 内直连,不跳浏览器)。
///
/// 走 IAM 的**原生 auth API**(`/auth/v1/*`),不是 OIDC 兼容层的 `/realms/user/*`。
/// 区别不只是路径:原生 API 收 JSON、回统一信封 `{code,msg,data,trace_id}`,
/// 登录结果 `data` 是 TokenBundle,里面**自带 username** —— 于是不需要再单独
/// 请求一次 userinfo,登录返回时昵称就已经在手上了。
///
/// 两条链路签出来的 access token 是同一个函数(服务端 `TokenService.SignAccess`)
/// 产的,audience 都等于传入的 client_id,所以 dreamreader-sync 一视同仁。
///
/// 【服务端前置】IAM 的 consumers 表里必须有本 client_id 且 `allowed_grants`
/// 含 `password`(登录 / 注册)与 `refresh_token`(续期)。缺注册回 4001,
/// 缺授权回 4003 —— 两个码分得开,照着查即可。
///
/// token 存 [FlutterSecureStorage](Android Keystore / Windows DPAPI),不落明文 prefs。
class IamAuth {
  IamAuth({Dio? httpClient, FlutterSecureStorage? storage})
      : _injectedDio = httpClient,
        _storage = storage ?? const FlutterSecureStorage();

  static final IamAuth instance = IamAuth();

  final Dio? _injectedDio;
  final FlutterSecureStorage _storage;

  /// IAM 基址(如 https://account.64hz.cn),末尾无斜杠。
  String issuer = '';

  /// 本 App 在 IAM 注册的 client_id(= access token 的 audience)。
  String clientId = '';

  String? _accessToken;
  String? _refreshToken;
  int _expiresAtMs = 0;
  String? _username;
  String? _uid;
  String? _sid;
  String? _deviceId; // 稳定设备标识,IAM 用它区分会话

  bool get isLoggedIn => _refreshToken?.isNotEmpty ?? false;
  String? get username => _username;
  String? get uid => _uid;

  /// 当前会话 id。服务端的「其它设备登录情况」用得上。
  String? get sid => _sid;

  static const _kAccess = 'iam.access';
  static const _kRefresh = 'iam.refresh';
  static const _kExpiresAt = 'iam.expiresAt';
  static const _kUsername = 'iam.username';
  static const _kUid = 'iam.uid';
  static const _kSid = 'iam.sid';
  static const _kDeviceId = 'iam.deviceId';

  // ---- 服务端策略的客户端镜像 ----
  // 与 services/iam/account/validation.go 和 credential/password.go 保持一致。
  // 目的只是即时反馈(少一次往返、少一次发码浪费),**不是**信任边界 ——
  // 真正的判定永远在服务端,这里放过去的服务端照样会拒。

  static final RegExp _usernameRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,31}$');
  static final RegExp _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// 字母开头,3~32 位,只允许字母 / 数字 / 下划线。
  static bool isValidUsername(String s) => _usernameRe.hasMatch(s.trim());

  static bool isEmail(String s) => _emailRe.hasMatch(s.trim());

  /// 8~72 位(72 是 bcrypt 上限),且至少各有一个字母和一个数字。
  static bool isValidPassword(String s) {
    if (s.length < 8 || s.length > 72) return false;
    var letter = false, digit = false;
    for (final r in s.runes) {
      final c = String.fromCharCode(r);
      if (RegExp(r'[a-zA-Z]').hasMatch(c)) letter = true;
      if (RegExp(r'[0-9]').hasMatch(c)) digit = true;
    }
    return letter && digit;
  }

  /// 验证码位数与有效期(服务端 EmailCodeService 的默认值),UI 用来做输入框
  /// 长度限制和「x 秒后可重发」倒计时。
  static const codeLength = 6;
  static const codeResendCooldown = Duration(seconds: 60);

  /// 读回持久化的 token 与配置。
  Future<void> load({required String issuer, required String clientId}) async {
    configure(issuer: issuer, clientId: clientId);
    _accessToken = await _storage.read(key: _kAccess);
    _refreshToken = await _storage.read(key: _kRefresh);
    _expiresAtMs =
        int.tryParse(await _storage.read(key: _kExpiresAt) ?? '') ?? 0;
    _username = await _storage.read(key: _kUsername);
    _uid = await _storage.read(key: _kUid);
    _sid = await _storage.read(key: _kSid);
    _deviceId = await _storage.read(key: _kDeviceId);
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = 'dmr-${_randomId()}';
      await _storage.write(key: _kDeviceId, value: _deviceId);
    }
  }

  /// 只更新 issuer/clientId。
  void configure({required String issuer, required String clientId}) {
    this.issuer = _normIssuer(issuer);
    this.clientId = clientId.trim();
  }

  Dio _dio() =>
      _injectedDio ??
      Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        contentType: Headers.jsonContentType,
        // 业务失败也是 200 以外的状态 + 信封里的 code;4xx 我们自己读信封,
        // 只有 5xx / 网络异常才抛。
        validateStatus: (s) => s != null && s < 500,
      ));

  // ---- 账号动作 ----

  /// 发一封验证码邮件。[locale] 决定邮件语言(如 `zh`/`en`),留空由服务端定。
  ///
  /// 冷却由服务端强制(默认 60s),撞上回 [IamErr.codeCooldown]。
  Future<void> sendCode({
    required String email,
    required IamCodeScene scene,
    String? locale,
  }) async {
    _requireConfig();
    final r = await _post('/auth/v1/code/send', {
      'email': email.trim(),
      'scene': scene.wire,
      if (locale != null && locale.isNotEmpty) 'locale': locale,
    });
    _envelope(r); // 只校验 code==0,没有 data
  }

  /// 注册并直接登录(服务端注册成功即返回 TokenBundle,不必再登一次)。
  Future<void> signup({
    required String email,
    required String code,
    required String username,
    required String password,
  }) async {
    _requireConfig();
    final r = await _post('/auth/v1/signup', {
      'email': email.trim(),
      'code': code.trim(),
      'username': username.trim(),
      'password': password,
      'device_id': _deviceId,
      'client_id': clientId,
    });
    await _consumeBundle(r);
  }

  /// 账号密码登录。[account] 可以是邮箱,也可以是用户名 —— 服务端两者都认。
  Future<void> loginPassword({
    required String account,
    required String password,
  }) async {
    _requireConfig();
    final r = await _post('/auth/v1/login/password', {
      'account': account.trim(),
      'password': password,
      'device_id': _deviceId,
      'client_id': clientId,
    });
    await _consumeBundle(r);
  }

  /// 用邮箱验证码重设密码(scene=reset)。成功后不自动登录,由 UI 引导去登录页 ——
  /// 服务端这个接口只回普通信封,没有 token。
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    _requireConfig();
    final r = await _post('/auth/v1/password/reset', {
      'email': email.trim(),
      'code': code.trim(),
      'new_password': newPassword,
    });
    _envelope(r);
  }

  // ---- token ----

  /// 进行中的刷新。refresh 是**轮换**的,服务端还带重放检测:两个调用各自拿同
  /// 一个旧 refresh_token 去换,后到的那个会被判成重放,**整个会话直接吊销**
  /// (错误码 3002)。所以并发刷新必须合并成一次,后来者等同一个 Future。
  Future<String?>? _refreshing;

  /// 返回一个可用的 access token;快过期(留 30s 余量)就先续期。
  /// 未登录 / 续期失败返回 null。
  Future<String?> validAccessToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((_accessToken?.isNotEmpty ?? false) && now < _expiresAtMs - 30000) {
      return _accessToken;
    }
    if (_refreshToken == null || _refreshToken!.isEmpty) return null;

    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final started = _refresh();
    _refreshing = started;
    try {
      return await started;
    } finally {
      _refreshing = null;
    }
  }

  Future<String?> _refresh() async {
    try {
      final r = await _post('/auth/v1/token/refresh', {
        'refresh_token': _refreshToken,
        'client_id': clientId,
      });
      await _consumeBundle(r);
      return _accessToken;
    } on IamException catch (e) {
      // 只有「这个 refresh 确实不能用了」才清登录态。其余(限流、服务端 5xx
      // 打成的业务错、consumer 配置一时不对)都当临时故障 —— 旧的实现在任何
      // 4xx 上都 logout,于是网关抖一下用户就被踢下线,得重登一次。
      if (e.code == IamErr.invalidToken ||
          e.code == IamErr.refreshReused ||
          e.code == IamErr.unauthorized) {
        await logout();
      }
      return null;
    } catch (_) {
      return null; // 网络异常:保留登录态,下次再试
    }
  }

  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAtMs = 0;
    _username = null;
    _uid = null;
    _sid = null;
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kExpiresAt);
    await _storage.delete(key: _kUsername);
    await _storage.delete(key: _kUid);
    await _storage.delete(key: _kSid);
    // device_id 保留:它标识这台设备,不随登录态走。
  }

  // ---- 传输与信封 ----

  Future<Response<dynamic>> _post(String path, Map<String, dynamic> body) =>
      _dio().post<dynamic>('$issuer$path', data: body);

  /// 校验统一信封并返回 `data`。非 0 的 code 一律抛 [IamException]。
  Map<String, dynamic>? _envelope(Response<dynamic> r) {
    final raw = r.data;
    final Map<String, dynamic> body;
    if (raw is Map<String, dynamic>) {
      body = raw;
    } else if (raw is String && raw.isNotEmpty) {
      // 少数网关会把 JSON 当纯文本回来。
      try {
        body = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        throw IamException(IamErr.internal, 'HTTP ${r.statusCode}');
      }
    } else {
      throw IamException(IamErr.internal, 'HTTP ${r.statusCode}');
    }
    final code = (body['code'] as num?)?.toInt() ?? IamErr.internal;
    final traceId = body['trace_id'] as String?;
    if (code != IamErr.ok) {
      throw IamException(code, (body['msg'] as String?) ?? 'HTTP ${r.statusCode}',
          traceId: traceId);
    }
    return body['data'] as Map<String, dynamic>?;
  }

  /// 吃下一个 TokenBundle 信封并落盘。
  Future<void> _consumeBundle(Response<dynamic> r) async {
    final data = _envelope(r);
    final access = data?['access_token'] as String?;
    if (data == null || access == null || access.isEmpty) {
      throw IamException(IamErr.internal, '登录响应缺少 access_token');
    }
    _accessToken = access;
    final refresh = data['refresh_token'] as String?;
    if (refresh != null && refresh.isNotEmpty) _refreshToken = refresh;
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 900;
    _expiresAtMs = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    // TokenBundle 自带这三样,不必再跑一趟 userinfo —— 登录返回时昵称就已就位,
    // UI 不需要「先显示占位、过会儿再刷一次」。
    final name = data['username'] as String?;
    if (name != null && name.isNotEmpty) _username = name;
    _uid = (data['uid'] as String?) ?? _uid;
    _sid = (data['sid'] as String?) ?? _sid;
    await _persist();
  }

  Future<void> _persist() async {
    await _storage.write(key: _kAccess, value: _accessToken);
    await _storage.write(key: _kRefresh, value: _refreshToken);
    await _storage.write(key: _kExpiresAt, value: '$_expiresAtMs');
    if (_username != null) {
      await _storage.write(key: _kUsername, value: _username);
    }
    if (_uid != null) await _storage.write(key: _kUid, value: _uid);
    if (_sid != null) await _storage.write(key: _kSid, value: _sid);
  }

  void _requireConfig() {
    if (issuer.isEmpty) throw IamException(IamErr.invalidRequest, '未配置 IAM 地址');
    if (clientId.isEmpty) {
      throw IamException(IamErr.invalidRequest, '未配置 client_id');
    }
  }

  static String _normIssuer(String u) {
    var s = u.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 设备标识用的随机串。这不是安全凭据(只用于区分会话),用时间戳 + hashCode
  /// 足够;真正的凭据由服务端签发。
  static String _randomId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return '${now.toRadixString(36)}${identityHashCode(now).toRadixString(36)}';
  }

  @visibleForTesting
  void debugSeedTokens({
    String? access,
    String? refresh,
    int expiresAtMs = 0,
    String deviceId = 'dmr-test',
  }) {
    _accessToken = access;
    _refreshToken = refresh;
    _expiresAtMs = expiresAtMs;
    _deviceId = deviceId;
  }
}
