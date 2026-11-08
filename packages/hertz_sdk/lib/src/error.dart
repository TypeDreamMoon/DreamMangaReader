/// 出错的种类。调用方按这个分支，不要去看 HTTP 状态码的数字。
enum HertzErrorKind {
  /// 连不上、超时——**注意：不代表没成功**。
  network,

  /// 404
  notFound,

  /// 401
  unauthorized,

  /// 409：记录存在，但版本不是你给的那个（或 createOnly 时记录已存在）
  conflict,

  /// 412：你给了 If-Match，但记录不存在——没有「当前版本」可比
  preconditionFailed,

  /// 413
  tooLarge,

  /// 其他 4xx
  badRequest,

  /// 429
  rateLimited,

  /// 5xx
  server,

  other,
}

/// 把 HTTP 状态码翻译成 [HertzErrorKind]。
HertzErrorKind kindFromStatus(int status) {
  if (status == 0) return HertzErrorKind.network;
  if (status == 401) return HertzErrorKind.unauthorized;
  if (status == 404) return HertzErrorKind.notFound;
  if (status == 409) return HertzErrorKind.conflict;
  if (status == 412) return HertzErrorKind.preconditionFailed;
  if (status == 413) return HertzErrorKind.tooLarge;
  if (status == 429) return HertzErrorKind.rateLimited;
  if (status >= 500) return HertzErrorKind.server;
  if (status >= 400) return HertzErrorKind.badRequest;
  return HertzErrorKind.other;
}

/// 一切失败的统一类型。
///
/// 刻意不给「超时」单独一个种类：超时和连接失败在调用方看来是同一件事——
/// **都不知道服务端到底做没做**。要区分「确定没做」和「不知道」，
/// 得靠幂等键或者业务层对账，不是靠错误码。
class HertzException implements Exception {
  const HertzException(
    this.kind,
    this.status,
    this.message, {
    this.path = '',
    this.code = 0,
  });

  final HertzErrorKind kind;

  /// HTTP 状态码；网络层失败为 0。
  final int status;
  final String message;
  final String path;

  /// 服务端信封里的业务错误码（`{"code":7001,"msg":"..."}`，见 [HertzErrorCode]）。
  /// HEAD 响应没有 body，取自 `X-Error-Code` 头。
  /// 0 表示服务端没给（网络错误、反代 / 别的服务回的非信封响应、或老版本服务端）。
  final int code;

  bool get isNotFound => kind == HertzErrorKind.notFound;
  bool get isUnauthorized => kind == HertzErrorKind.unauthorized;
  bool get isConflict => kind == HertzErrorKind.conflict;
  bool get isPreconditionFailed => kind == HertzErrorKind.preconditionFailed;
  bool get isTooLarge => kind == HertzErrorKind.tooLarge;
  bool get isNetwork => kind == HertzErrorKind.network;

  /// 值得重试吗。只重试「可能是暂时的」那几类——
  /// 4xx 是调用方自己的错，重试多少次都一样。
  ///
  /// 408 是例外：它是「服务端等这个请求等超时了」，不是参数写错。
  /// Azure SDK 默认把 408 和 429/500/502/503/504 一起重试，这里跟它对齐。
  bool get retryable =>
      status == 408 ||
      kind == HertzErrorKind.network ||
      kind == HertzErrorKind.server ||
      kind == HertzErrorKind.rateLimited;

  @override
  String toString() =>
      'HertzException(${kind.name}, HTTP $status, code $code): $message';
}

/// 服务端契约里的业务错误码（`hertz-appdata/packages/contracts/errors/error_codes.yaml`）。
///
/// 和 HTTP 状态码不是一回事：同样是 404，`notFound` 是**数据服务自己**说「没有这条」，
/// 而 `code == 0` 的 404 多半是地址配错了（反代 / 别的服务回的 `404 page not found`）。
/// 把后者当成「云端没数据」，接下来一次推送就可能把真数据盖掉。
abstract final class HertzErrorCode {
  static const ok = 0;
  static const internal = 1;
  static const invalidRequest = 1001;
  static const unauthorized = 1002;
  static const forbidden = 1003;
  static const notFound = 1004;
  static const rateLimited = 1005;
  static const invalidToken = 3001;
  static const versionConflict = 7001;
  static const preconditionFailed = 7002;
  static const payloadTooLarge = 7003;
  static const appNotAllowed = 7004;
  static const writeDenied = 7005;
  static const quotaExceeded = 7006;
  static const invalidPermission = 7007;
  static const invalidKey = 7008;
  static const serviceUnavailable = 7009;
}
