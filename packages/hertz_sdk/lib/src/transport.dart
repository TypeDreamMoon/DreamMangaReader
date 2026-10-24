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
class IoTransport implements HertzTransport {
  IoTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<HertzResponse> send(HertzRequest req) async {
    final timeout = Duration(milliseconds: req.timeoutMs);
    final uri = Uri.parse(req.url);

    _client.connectionTimeout = timeout;

    final hreq = await _client.openUrl(req.method, uri).timeout(timeout);
    for (final kv in req.headers.entries) {
      hreq.headers.set(kv.key, kv.value);
    }
    final body = req.body;
    if (body != null && body.isNotEmpty) {
      hreq.add(body);
    }

    final hresp = await hreq.close().timeout(timeout);

    final builder = BytesBuilder(copy: false);
    await for (final chunk in hresp) {
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
}
