import 'package:dio/dio.dart';

/// GitHub OAuth **设备码流**(Device Flow)—— 拉私有源仓库的「登录」,替代手动粘贴 PAT。
///
/// 流程:请求设备码 → 展示 user_code + 让用户去 github.com/login/device 输码授权 →
/// 轮询换 access_token → 当作源仓库 token 用(_fetch 照旧 Bearer)。
///
/// 【一次性配置】需在 GitHub 注册一个 OAuth App 并开启 Device Flow:
///   GitHub → Settings → Developer settings → OAuth Apps → New OAuth App
///   勾选「Enable Device Flow」,Client ID 填到下面默认值(**公开值,非密钥**,
///   Device Flow 不需要 client secret,烤进代码是官方允许的做法)。
///   构建时 `--dart-define=GITHUB_CLIENT_ID=xxx` 可覆盖(优先;别传空串,会盖掉默认值)。
const String kGithubOAuthClientId = String.fromEnvironment(
  'GITHUB_CLIENT_ID',
  defaultValue: 'Ov23likQJd7IwZyP0E3k', // TypeDreamMoon 的 OAuth App(已开 Device Flow)
);

class GithubDeviceCode {
  GithubDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode; // 展示给用户去网页输入的码
  final String verificationUri; // 通常 https://github.com/login/device
  final int expiresIn; // 秒
  final int interval; // 轮询最小间隔(秒)
}

class GithubOAuth {
  static bool get configured => kGithubOAuthClientId.isNotEmpty;

  /// 第一步:申请设备码。scope=repo 以便读私有仓库。
  static Future<GithubDeviceCode> startDeviceFlow({String scope = 'repo'}) async {
    if (!configured) {
      throw Exception('未配置 GitHub OAuth Client ID(见 github_oauth.dart 注释)');
    }
    final dio = Dio();
    final r = await dio.post<Map<String, dynamic>>(
      'https://github.com/login/device/code',
      data: {'client_id': kGithubOAuthClientId, 'scope': scope},
      options: Options(
        headers: {'Accept': 'application/json'},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
    final d = r.data ?? const {};
    if (d['device_code'] == null) {
      throw Exception('GitHub 未返回设备码:${d['error'] ?? d}');
    }
    return GithubDeviceCode(
      deviceCode: d['device_code'] as String,
      userCode: d['user_code'] as String,
      verificationUri:
          (d['verification_uri'] as String?) ?? 'https://github.com/login/device',
      expiresIn: (d['expires_in'] as num?)?.toInt() ?? 900,
      interval: (d['interval'] as num?)?.toInt() ?? 5,
    );
  }

  /// 第二步:轮询换 token。用户在网页授权后返回 access_token;超时/取消/过期抛异常。
  /// [onWaiting] 每次轮询回调(供 UI 显示「等待授权…」)。
  static Future<String> pollForToken(
    GithubDeviceCode dc, {
    void Function()? onWaiting,
    bool Function()? cancelled,
  }) async {
    final dio = Dio();
    var interval = dc.interval;
    final deadline = DateTime.now().add(Duration(seconds: dc.expiresIn));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: interval));
      if (cancelled?.call() ?? false) throw Exception('已取消');
      onWaiting?.call();
      final r = await dio.post<Map<String, dynamic>>(
        'https://github.com/login/oauth/access_token',
        data: {
          'client_id': kGithubOAuthClientId,
          'device_code': dc.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
        options: Options(
          headers: {'Accept': 'application/json'},
          contentType: Headers.formUrlEncodedContentType,
        ),
      );
      final d = r.data ?? const {};
      final token = d['access_token'] as String?;
      if (token != null && token.isNotEmpty) return token;
      switch (d['error']) {
        case 'authorization_pending':
          continue; // 还没授权,继续等
        case 'slow_down':
          interval += 5; // GitHub 要求放慢
          continue;
        case 'expired_token':
          throw Exception('授权码已过期,请重新登录');
        case 'access_denied':
          throw Exception('已取消授权');
        default:
          throw Exception('GitHub: ${d['error'] ?? '未知错误'}');
      }
    }
    throw Exception('授权超时');
  }
}
