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

final class DownloadFailure {
  const DownloadFailure({
    required this.code,
    required this.message,
    required this.detail,
    required this.retryCount,
    this.httpStatus,
  });

  factory DownloadFailure.fromMessage(
    DownloadFailureCode code,
    String detail, {
    String? message,
    int retryCount = 0,
    int? httpStatus,
  }) {
    return DownloadFailure(
      code: code,
      message: message ?? _defaultMessage(code),
      detail: sanitizeDownloadFailureDetail(detail),
      retryCount: retryCount,
      httpStatus: httpStatus,
    );
  }

  final DownloadFailureCode code;
  final String message;
  final String detail;
  final int retryCount;
  final int? httpStatus;

  Map<String, Object?> toJson() => {
        'code': code.name,
        'message': message,
        'detail': sanitizeDownloadFailureDetail(detail),
        'retryCount': retryCount,
        if (httpStatus != null) 'httpStatus': httpStatus,
      };

  factory DownloadFailure.fromJson(Map<String, Object?> json) {
    return DownloadFailure(
      code: _failureCode(_string(json, 'code')),
      message: _string(json, 'message'),
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
          message == other.message &&
          detail == other.detail &&
          retryCount == other.retryCount &&
          httpStatus == other.httpStatus;

  @override
  int get hashCode => Object.hash(
        code,
        message,
        detail,
        retryCount,
        httpStatus,
      );
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

String _defaultMessage(DownloadFailureCode code) => switch (code) {
      DownloadFailureCode.network => '网络连接失败',
      DownloadFailureCode.authenticationRequired => '需要重新登录',
      DownloadFailureCode.sourceRefreshRequired => '等待源刷新',
      DownloadFailureCode.resourceMissing => '资源不存在',
      DownloadFailureCode.insufficientStorage => '存储空间不足',
      DownloadFailureCode.storageUnavailable => '下载目录不可用',
      DownloadFailureCode.unsafePath => '下载路径不安全',
      DownloadFailureCode.corruptResource => '下载文件已损坏',
      DownloadFailureCode.unsupportedDrm => '不支持此 DRM 离线内容',
      DownloadFailureCode.cancelled => '下载已取消',
      DownloadFailureCode.unknown => '下载失败',
    };

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
