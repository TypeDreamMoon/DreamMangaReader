import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class FaultRoute {
  FaultRoute({
    required this.body,
    this.contentType = 'application/octet-stream',
    this.failuresBeforeSuccess = 0,
    this.chunks,
    this.beforeChunk,
    this.redirectTo,
    this.redirectStatus = HttpStatus.movedTemporarily,
  });

  final List<int> body;
  final String contentType;
  int failuresBeforeSuccess;
  final List<List<int>>? chunks;
  final Future<void> Function(int index)? beforeChunk;

  /// 非空时该路由返回一个跳转而不是内容,用来验证上游准入策略是否逐跳校验。
  final String? redirectTo;
  final int redirectStatus;
}

class RecordedRequest {
  const RecordedRequest({
    required this.path,
    required this.authorization,
    required this.range,
  });

  final String path;
  final String? authorization;
  final String? range;
}

class FaultHttpServer {
  FaultHttpServer._(this._server) {
    _subscription = _server.listen(_handle);
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final Map<String, FaultRoute> routes = {};
  final List<RecordedRequest> requests = [];

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}/');

  static Future<FaultHttpServer> start() async => FaultHttpServer._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      );

  int requestCount(String path) =>
      requests.where((request) => request.path == path).length;

  void addText(
    String path,
    String text, {
    String contentType = 'application/vnd.apple.mpegurl',
    int failuresBeforeSuccess = 0,
  }) {
    routes[path] = FaultRoute(
      body: Uint8List.fromList(text.codeUnits),
      contentType: contentType,
      failuresBeforeSuccess: failuresBeforeSuccess,
    );
  }

  void addBytes(
    String path,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
    int failuresBeforeSuccess = 0,
  }) {
    routes[path] = FaultRoute(
      body: bytes,
      contentType: contentType,
      failuresBeforeSuccess: failuresBeforeSuccess,
    );
  }

  void addChunked(
    String path,
    List<List<int>> chunks, {
    String contentType = 'application/octet-stream',
    Future<void> Function(int index)? beforeChunk,
  }) {
    routes[path] = FaultRoute(
      body: chunks.expand((chunk) => chunk).toList(),
      contentType: contentType,
      chunks: chunks,
      beforeChunk: beforeChunk,
    );
  }

  void addRedirect(
    String path,
    String location, {
    int status = HttpStatus.movedTemporarily,
  }) {
    routes[path] = FaultRoute(
      body: const [],
      redirectTo: location,
      redirectStatus: status,
    );
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add(RecordedRequest(
      path: request.uri.path,
      authorization: request.headers.value(HttpHeaders.authorizationHeader),
      range: request.headers.value(HttpHeaders.rangeHeader),
    ));
    final route = routes[request.uri.path];
    if (route == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final redirectTo = route.redirectTo;
    if (redirectTo != null) {
      request.response.statusCode = route.redirectStatus;
      request.response.headers.set(HttpHeaders.locationHeader, redirectTo);
      await request.response.close();
      return;
    }
    if (route.failuresBeforeSuccess > 0) {
      route.failuresBeforeSuccess--;
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
      return;
    }
    var bytes = route.body;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
      if (match == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      bytes = bytes.sublist(start, end + 1);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${route.body.length}',
      );
    }
    request.response.headers.contentType = ContentType.parse(route.contentType);
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range == null && route.chunks != null) {
      request.response.bufferOutput = false;
      request.response.headers.chunkedTransferEncoding = true;
      for (var index = 0; index < route.chunks!.length; index++) {
        await route.beforeChunk?.call(index);
        request.response.add(route.chunks![index]);
        await request.response.flush();
      }
      await request.response.close();
      return;
    }
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}
