import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// B站 Web 端浏览器 UA。风控对 UA 敏感,统一用一个稳定的桌面 Chrome UA。
const String kBiliUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 二维码轮询结果码(B站官方语义)。
enum BiliQrState {
  waiting, // 86101 未扫码
  scanned, // 86090 已扫码待确认
  success, // 0 登录成功
  expired, // 86038 二维码失效
  error, // 网络/其他
}

/// Bilibili 账号态(扫码登录 + Cookie 安全存储)。镜像项目里 IamAuth 的单例 + 安全存储模式:
/// Cookie(含 SESSDATA / bili_jct / DedeUserID)存 [FlutterSecureStorage](Android Keystore /
/// Windows DPAPI),**永不进入云同步 / 导出**(和 API key 同一红线)。
class BiliAuth extends ChangeNotifier {
  BiliAuth._();
  static final BiliAuth instance = BiliAuth._();

  static const _storage = FlutterSecureStorage();
  static const _kCookie = 'bili.cookie';
  static const _kMid = 'bili.mid';
  static const _kUname = 'bili.uname';

  String? _cookie;
  String? _uname;
  int _mid = 0;

  /// 已登录 = 有 SESSDATA。
  bool get isLoggedIn => (_cookie?.contains('SESSDATA=') ?? false);
  String get cookie => _cookie ?? '';
  String? get uname => _uname;
  int get mid => _mid;

  Future<void> load() async {
    try {
      _cookie = await _storage.read(key: _kCookie);
      _uname = await _storage.read(key: _kUname);
      _mid = int.tryParse(await _storage.read(key: _kMid) ?? '') ?? 0;
    } catch (_) {
      // 安全存储偶发解密失败(换机/迁移):当未登录处理,不崩。
      _cookie = null;
      _uname = null;
      _mid = 0;
    }
    notifyListeners();
  }

  Dio _dio() => Dio(BaseOptions(
        headers: {
          'User-Agent': kBiliUa,
          'Referer': 'https://www.bilibili.com/',
        },
        // 轮询 pending 时 B站返回 200 + code≠0,不该抛;放宽到全部状态自行判读。
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ));

  /// 生成登录二维码:返回 (二维码内容 url, 轮询用 qrcode_key)。
  Future<({String url, String key})> qrGenerate() async {
    final r = await _dio().get(
        'https://passport.bilibili.com/x/passport-login/web/qrcode/generate');
    final d = (r.data as Map)['data'] as Map;
    return (url: d['url'] as String, key: d['qrcode_key'] as String);
  }

  /// 轮询二维码状态;success 时从 Set-Cookie 落盘 Cookie。
  Future<BiliQrState> qrPoll(String key) async {
    try {
      final r = await _dio().get(
        'https://passport.bilibili.com/x/passport-login/web/qrcode/poll',
        queryParameters: {'qrcode_key': key},
      );
      final d = (r.data as Map)['data'] as Map?;
      final code = (d?['code'] as num?)?.toInt() ?? -1;
      switch (code) {
        case 0:
          await _saveCookies(
              r.headers.map['set-cookie'] ?? const [], d?['url'] as String?);
          // 只有真拿到 SESSDATA 才算登录成功;否则回 error,避免「成功却未登录」的错乱流。
          return isLoggedIn ? BiliQrState.success : BiliQrState.error;
        case 86090:
          return BiliQrState.scanned;
        case 86101:
          return BiliQrState.waiting;
        case 86038:
          return BiliQrState.expired;
        default:
          return BiliQrState.error;
      }
    } catch (_) {
      return BiliQrState.error;
    }
  }

  /// 从 Set-Cookie(登录成功回包)解析并存 Cookie。部分环境 Set-Cookie 缺失时,
  /// 回退从跳转 [url] 的 query 里捞(B站有时把票据放 url)。
  Future<void> _saveCookies(List<String> setCookies, String? url) async {
    final jar = <String, String>{};
    for (final sc in setCookies) {
      final kv = sc.split(';').first.trim();
      final eq = kv.indexOf('=');
      if (eq > 0) jar[kv.substring(0, eq)] = kv.substring(eq + 1);
    }
    if (jar['SESSDATA'] == null && url != null) {
      try {
        // ⚠️ 用 **原始 query**(不解码)。SESSDATA 在 url 里是百分号编码的
        // (含 %2C/%2A),`Uri.queryParameters` 会解码 → 存下的票据被破坏,
        // 后续带这个 Cookie 的鉴权请求全 -101。原始拆分保留编码,和 Set-Cookie 路径一致。
        for (final pair in Uri.parse(url).query.split('&')) {
          final i = pair.indexOf('=');
          if (i <= 0) continue;
          final k = pair.substring(0, i);
          if (const {'SESSDATA', 'bili_jct', 'DedeUserID', 'DedeUserID__ckMd5'}
              .contains(k)) {
            jar[k] = pair.substring(i + 1);
          }
        }
      } catch (_) {}
    }
    const want = [
      'SESSDATA',
      'bili_jct',
      'DedeUserID',
      'DedeUserID__ckMd5',
      'sid',
    ];
    final parts = <String>[
      for (final k in want)
        if (jar[k] != null && jar[k]!.isNotEmpty) '$k=${jar[k]}',
    ];
    if (parts.isEmpty) return; // 没拿到票据,视为失败,保持未登录
    _cookie = parts.join('; ');
    _mid = int.tryParse(jar['DedeUserID'] ?? '') ?? 0;
    await _storage.write(key: _kCookie, value: _cookie);
    await _storage.write(key: _kMid, value: '$_mid');
    notifyListeners();
  }

  /// nav 拿到昵称后回填(展示用)。
  Future<void> setProfile({String? uname, int? mid}) async {
    var changed = false;
    if (uname != null && uname.isNotEmpty && uname != _uname) {
      _uname = uname;
      await _storage.write(key: _kUname, value: uname);
      changed = true;
    }
    if (mid != null && mid > 0 && mid != _mid) {
      _mid = mid;
      await _storage.write(key: _kMid, value: '$mid');
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> logout() async {
    _cookie = null;
    _uname = null;
    _mid = 0;
    await _storage.delete(key: _kCookie);
    await _storage.delete(key: _kMid);
    await _storage.delete(key: _kUname);
    notifyListeners();
  }
}
