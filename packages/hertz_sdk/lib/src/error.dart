/// 出错的种类。调用方按这个分支，不要去看 HTTP 状态码的数字。
enum HertzErrorKind {
  /// 连不上、超时——**注意：不代表没成功**。
  network,

  /// 404
  notFound,

  /// 401
  unauthorized,

  /// 409
  conflict,

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

  /// 服务端信封里的业务错误码（`{"code":409,"msg":"..."}`）。
  /// 0 表示服务端没给（网络错误、或老版本服务端）。
  final int code;

  bool get isNotFound => kind == HertzErrorKind.notFound;
  bool get isUnauthorized => kind == HertzErrorKind.unauthorized;
  bool get isConflict => kind == HertzErrorKind.conflict;
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
