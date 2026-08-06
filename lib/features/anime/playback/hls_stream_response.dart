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

  String? get acceptRanges =>
      headers[HttpHeaders.acceptRangesHeader]?.firstOrNull;

  Future<List<int>> readAll() =>
      stream.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
}
