enum DownloadFailureCode {
  network,
  authenticationRequired,
  sourceRefreshRequired,
  resourceMissing,
  insufficientStorage,
  storageUnavailable,
  unsafePath,
  corruptResource,
  unsupportedDrm,
  cancelled,
  unknown,
}

/// 一次下载失败的机器可读记录。
///
/// **刻意不带面向用户的文案**:core 层拿不到 BuildContext,写死一门语言就等于
/// 让另外三种语言的用户看中文。UI 按 [code] 映射 l10n,[detail] 是已脱敏的
/// 原始错误串,只在用户展开时展示。
final class DownloadFailure {
  const DownloadFailure({
    required this.code,
    required this.detail,
    required this.retryCount,
    this.httpStatus,
  });

  factory DownloadFailure.fromDetail(
    DownloadFailureCode code,
    String detail, {
    int retryCount = 0,
    int? httpStatus,
  }) {
    return DownloadFailure(
      code: code,
      detail: sanitizeDownloadFailureDetail(detail),
      retryCount: retryCount,
      httpStatus: httpStatus,
    );
  }

  final DownloadFailureCode code;
  final String detail;
  final int retryCount;
  final int? httpStatus;

  Map<String, Object?> toJson() => {
        'code': code.name,
        'detail': sanitizeDownloadFailureDetail(detail),
        'retryCount': retryCount,
        if (httpStatus != null) 'httpStatus': httpStatus,
      };

  factory DownloadFailure.fromJson(Map<String, Object?> json) {
    return DownloadFailure(
      code: _failureCode(_string(json, 'code')),
      detail: sanitizeDownloadFailureDetail(_string(json, 'detail')),
      retryCount: _integer(json, 'retryCount'),
      httpStatus:
          json['httpStatus'] == null ? null : _integer(json, 'httpStatus'),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadFailure &&
          code == other.code &&
          detail == other.detail &&
          retryCount == other.retryCount &&
          httpStatus == other.httpStatus;

  @override
  int get hashCode => Object.hash(
        code,
        detail,
        retryCount,
        httpStatus,
      );
}

extension DownloadFailureCodeRetry on DownloadFailureCode {
  /// 值得自动重试的错误码:只包含「等一会儿可能就好了」的暂时性故障。
  /// 认证、资源不存在、磁盘满这类要用户介入,重试只是白跑三趟。
  bool get isRetryable => switch (this) {
        DownloadFailureCode.network ||
        DownloadFailureCode.sourceRefreshRequired =>
          true,
        _ => false,
      };
}

String sanitizeDownloadFailureDetail(String value) {
  var sanitized = value.replaceAllMapped(
    RegExp(r'https?://[^\s]+', caseSensitive: false),
    (match) {
      final uri = Uri.tryParse(match.group(0)!);
      if (uri == null) return '[download URL]';
      return uri
          .replace(query: '', fragment: '')
          .toString()
          .replaceFirst(RegExp(r'[?#]+$'), '');
    },
  );
  sanitized = sanitized.replaceAllMapped(
    RegExp(
      r'^(authorization|cookie)\s*:\s*.*$',
      caseSensitive: false,
      multiLine: true,
    ),
    (match) => '${match.group(1)}: [redacted]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'Bearer\s+[^\s]+', caseSensitive: false),
    'Bearer [redacted]',
  );
  return sanitized;
}

DownloadFailureCode _failureCode(String name) {
  for (final code in DownloadFailureCode.values) {
    if (code.name == name) return code;
  }
  throw FormatException('unknown failure code: $name');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('invalid $key');
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('invalid $key');
}
