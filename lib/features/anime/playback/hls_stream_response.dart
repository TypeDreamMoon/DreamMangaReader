import 'dart:io';

class HlsStreamResponse {
  const HlsStreamResponse({
    required this.statusCode,
    required this.stream,
    required this.headers,
    required this.cancel,
  });

  final int statusCode;
  final Stream<List<int>> stream;
  final Map<String, List<String>> headers;
  final Future<void> Function() cancel;

  String get contentType =>
      headers[HttpHeaders.contentTypeHeader]?.firstOrNull ??
      'application/octet-stream';

  int? get contentLength => int.tryParse(
        headers[HttpHeaders.contentLengthHeader]?.firstOrNull ?? '',
      );

  String? get contentRange =>
      headers[HttpHeaders.contentRangeHeader]?.firstOrNull;

  /// 上游声明的这一段有多少字节,不知道就是 null。
  ///
  /// chunked 响应没有 Content-Length,但 206 的 Content-Range 里同样写着这一段的
  /// 起止 —— 拿它当完整性的尺子,总好过拿「收到了多少」当「本该有多少」(那等于没查)。
  int? get declaredLength => contentLength ?? _contentRangeLength;

  int? get _contentRangeLength {
    final value = contentRange;
    if (value == null) return null;
    final match = RegExp(r'bytes\s+(\d+)\s*-\s*(\d+)\s*/').firstMatch(value);
    if (match == null) return null;
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    return end < start ? null : end - start + 1;
  }

  String? get acceptRanges =>
      headers[HttpHeaders.acceptRangesHeader]?.firstOrNull;

  Future<List<int>> readAll() =>
      stream.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
}
