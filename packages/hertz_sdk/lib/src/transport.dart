import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'types.dart';

/// 一次请求。body 为 null 表示没有请求体。
class HertzRequest {
  const HertzRequest({
    required this.method,
    required this.url,
    required this.timeoutMs,
    this.headers = const {},
    this.body,
  });

  final String method;
  final String url;
  final int timeoutMs;
  final Map<String, String> headers;
  final HertzBytes? body;
}

/// 一次响应。**headers 的 key 一律小写**，和 C++ 版一致。
class HertzResponse {
  const HertzResponse({
    required this.status,
    this.headers = const {},
    this.body,
  });

  /// 0 表示网络层失败（连不上 / 超时），不是 HTTP 状态码。
  final int status;
  final Map<String, String> headers;
  final HertzBytes? body;

  bool get ok => status >= 200 && status < 300;

  String header(String name) => headers[name.toLowerCase()] ?? '';

  String get bodyText {
    final b = body;
    if (b == null || b.isEmpty) return '';
    // 错误信息可能是非 UTF-8 的服务端返回，别因此再抛一次
    return utf8.decode(b, allowMalformed: true);
  }
}

/// 网络层接口。
///
/// **为什么单独抽出来**：默认实现绑死在 dart:io 上（Flutter Web 用不了），
/// 而且测试要用假网络层。换实现不用改 SDK 的业务逻辑——和 C++ 版
/// `IHttpTransport` 是同一个设计。
abstract class HertzTransport {
  Future<HertzResponse> send(HertzRequest req);
}

/// 默认实现：dart:io 的 HttpClient。Windows / Android / iOS / macOS / Linux 都可用。
///
/// 超时（[HertzRequest.timeoutMs]）分三段各自计：
///   - 建连 / 拿到请求对象
///   - 发完请求体并等到响应头
///   - 读响应体：**两块数据之间**最多等这么久（空闲超时，和 Dio 的 receiveTimeout 同义）
///
/// 任何一段超时都会**掐掉这条连接**再抛 [TimeoutException]——只抛不掐的话，
/// 一个卡在半路的响应体会一直占着连接，下次请求还可能复用到它。
/// 读响应体按空闲而不按总时长计，是为了大存档在慢网下不被误杀：只要还在来数据就等。
class IoTransport implements HertzTransport {
  IoTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<HertzResponse> send(HertzRequest req) async {
    final timeout = Duration(milliseconds: req.timeoutMs);
    final uri = Uri.parse(req.url);

    _client.connectionTimeout = timeout;

    final opening = _client.openUrl(req.method, uri);
    final HttpClientRequest hreq;
    try {
      hreq = await opening.timeout(timeout);
    } on TimeoutException {
      // openUrl 晚到了也要收尾，别留一条没人管的连接
      unawaited(opening.then((r) => r.abort(), onError: (Object _) {}));
      rethrow;
    }

    for (final kv in req.headers.entries) {
      hreq.headers.set(kv.key, kv.value);
    }
    final body = req.body;
    if (_sendsBody(req.method) || (body != null && body.isNotEmpty)) {
      // **必须声明定长**：不设 contentLength 时 dart:io 走 chunked 编码，
      // 而 appdata 要求 Content-Length（好在读包之前就按上限拒绝），chunked 直接回 400。
      hreq.contentLength = body?.length ?? 0;
    }
    if (body != null && body.isNotEmpty) {
      hreq.add(body);
    }

    final HttpClientResponse hresp;
    try {
      hresp = await hreq.close().timeout(timeout);
    } on TimeoutException catch (e) {
      hreq.abort(e);
      rethrow;
    }

    // Stream.timeout：两块数据之间超过 timeout 就往流里塞一个 TimeoutException；
    // await for 因此抛出时会取消订阅，dart:io 随之销毁这条连接（不会放回连接池）。
    final builder = BytesBuilder(copy: false);
    await for (final chunk in hresp.timeout(timeout)) {
      builder.add(chunk);
    }

    final headers = <String, String>{};
    hresp.headers.forEach((k, v) {
      headers[k.toLowerCase()] = v.join(', ');
    });

    return HertzResponse(
      status: hresp.statusCode,
      headers: headers,
      body: builder.takeBytes(),
    );
  }

  static bool _sendsBody(String method) {
    final m = method.toUpperCase();
    return m == 'PUT' || m == 'POST' || m == 'PATCH';
  }
}
