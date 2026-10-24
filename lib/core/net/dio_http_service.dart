import 'dart:io';

import 'package:dio/dio.dart';

import '../log/app_log.dart';
import '../source/source.dart';
import 'app_proxy.dart';

/// [HttpService] 的 dio 实现。P0 为基础版;后续接:
/// - cookie jar(cookie_jar / dio_cookie_manager)
/// - 每源 UA / Referer 拦截器
/// - 过盾:把 WebView 取到的 cf_clearance 注入这里
/// - 限速 / 429 退避
class DioHttpService implements HttpService {
  DioHttpService([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<HostResponse> fetch(HostRequest request) =>
      _fetch(request, allowProxyRetry: true);

  Future<HostResponse> _fetch(
    HostRequest request, {
    required bool allowProxyRetry,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final resp = await _dio.request<String>(
        request.url,
        data: request.body,
        options: Options(
          method: request.method,
          headers: request.headers,
          responseType: ResponseType.plain,
          sendTimeout: request.timeout,
          receiveTimeout: request.timeout,
          validateStatus: (_) => true, // 由源自行判定状态
        ),
      );
      sw.stop();
      logHttp(request.method, request.url, resp.statusCode ?? 0,
          (resp.data ?? '').length, sw.elapsedMilliseconds);
      return HostResponse(
        status: resp.statusCode ?? 0,
        headers: resp.headers.map.map((k, v) => MapEntry(k, v.join(', '))),
        body: resp.data ?? '',
      );
    } catch (e) {
      sw.stop();
      logHttpError(request.method, request.url, sw.elapsedMilliseconds, e);

      // 连接层失败时，先怀疑「代理没探到」，而不是「源坏了」。
      //
      // 很常见的时序：App 比代理先启动。启动那次 AppProxy 探到的是「没有代理」，
      // 之后所有请求都直连——被墙的源站全是 SocketException，用户看到的就是
      // 「源全部读不出来」。这里再探一次，探到了就重试，只重试一次。
      if (allowProxyRetry && _isConnectFailure(e)) {
        final switched = await AppProxy.retryDetect();
        if (switched) {
          AppLog.i.warn(
            LogCat.network,
            '连接失败，重探到代理 ${AppProxy.current}，重试一次 · ${request.url}',
          );
          return _fetch(request, allowProxyRetry: false);
        }
      }
      rethrow;
    }
  }

  /// 是不是「连不上」这一类（而不是 4xx/5xx 那种真的收到了响应）。
  static bool _isConnectFailure(Object e) {
    if (e is SocketException) return true;
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError) {
        return true;
      }
      return e.error is SocketException;
    }
    return false;
  }
}
