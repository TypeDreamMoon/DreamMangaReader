/// B 站接口失败的**归类**。
///
/// 这里只给码,不给文案 —— `core/` 不碰 l10n,由 UI 层按当前语言映射(和
/// [ProxySource] 同一套路子)。以前是把接口原样返回的 `message`/`code` 直接抛给
/// 用户,于是海外用户看到的是「取播放源失败:-10403」这种东西:既不知道发生了
/// 什么,也不知道该干嘛。
enum BiliFailure {
  /// 版权方按地区锁了。海外看国区番剧最常撞的就是这个,解法是挂代理。
  geoBlocked,

  /// 要登录。
  needsLogin,

  /// 要大会员。
  vipOnly,

  /// 被风控拦了(缺指纹 cookie / 请求太频繁)。
  rateLimited,

  /// 没这个东西(番剧下架、ep_id 失效)。
  notFound,

  /// 没归到类的。带上原始 message 供排查。
  unknown,
}

class BiliException implements Exception {
  const BiliException(this.failure, {this.code, this.detail});

  final BiliFailure failure;

  /// 接口返回的原始 code,排查用。
  final int? code;

  /// 接口返回的原始 message。**不直接展示**给用户 —— UI 按 [failure] 出文案。
  final String? detail;

  @override
  String toString() {
    final raw = [
      if (code != null) 'code=$code',
      if (detail != null && detail!.isNotEmpty) detail,
    ].join(' ');
    return raw.isEmpty ? 'BiliException(${failure.name})' : 'BiliException(${failure.name}, $raw)';
  }
}

/// 地区限制的错误码。B 站在不同接口上用了不止一个:
/// pgc(番剧)线常见 -10403,老接口和部分 CDN 用 -404 配一句地区文案。
const Set<int> _kGeoCodes = {-10403, 10403};
const Set<int> _kLoginCodes = {-101, -400, 10004001, 10004004};
const Set<int> _kVipCodes = {-10403000, 87008, 6002003};
const Set<int> _kBlockedCodes = {-412, -352, -509};
const Set<int> _kMissingCodes = {-404, 10003001};

/// 地区限制的文案关键词。**光靠码不够**:同一个 -404 可能是「没这个番」也可能是
/// 「你所在地区看不了」,只有文案能分开;而且简中/繁中/英文三种都得认
/// (Bstation 按 s_locale 返回繁中或英文)。
const List<String> _kGeoWords = [
  '地区', '地區', '区域', '區域', '限制', '仅限', '僅限',
  'area', 'region', 'territor',
];

const List<String> _kVipWords = ['大会员', '大會員', '会员', '會員', 'vip', 'premium'];

const List<String> _kLoginWords = ['登录', '登入', 'login', 'sign in'];

bool _hasAny(String text, List<String> words) {
  for (final w in words) {
    if (text.contains(w)) return true;
  }
  return false;
}

/// 把一次 B 站返回归类。[code] / [message] 取自响应体的同名字段。
///
/// 判定顺序是有讲究的:**先看文案再看码**。因为码的复用很凶(-404 既是「没这个
/// 番」也是「你这地区没有」),而文案是给人看的,反而更能说明到底怎么了。
BiliFailure biliFailureOf(int? code, String? message) {
  final text = (message ?? '').toLowerCase();

  if (text.isNotEmpty) {
    if (_hasAny(text, _kGeoWords)) return BiliFailure.geoBlocked;
    if (_hasAny(text, _kVipWords)) return BiliFailure.vipOnly;
    if (_hasAny(text, _kLoginWords)) return BiliFailure.needsLogin;
  }

  if (code == null) return BiliFailure.unknown;
  if (_kGeoCodes.contains(code)) return BiliFailure.geoBlocked;
  if (_kVipCodes.contains(code)) return BiliFailure.vipOnly;
  if (_kLoginCodes.contains(code)) return BiliFailure.needsLogin;
  if (_kBlockedCodes.contains(code)) return BiliFailure.rateLimited;
  if (_kMissingCodes.contains(code)) return BiliFailure.notFound;
  return BiliFailure.unknown;
}

/// 从响应体建异常。`code` 可能是 num 也可能是字符串(不同接口不一样)。
BiliException biliExceptionOf(Map<String, dynamic> body) {
  final raw = body['code'];
  final code = raw is num ? raw.toInt() : int.tryParse('$raw');
  final message = body['message']?.toString();
  return BiliException(
    biliFailureOf(code, message),
    code: code,
    detail: message,
  );
}
