import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../log/app_log.dart';
import '../source/source.dart';
import 'app_proxy.dart';

/// [HttpService] 的 dio 实现。P0 为基础版;后续接:
/// - cookie jar(cookie_jar / dio_cookie_manager)
/// - 每源 UA / Referer 拦截器
/// - 过盾:把 WebView 取到的 cf_clearance 注入这里
/// - 限速 / 429 退避
class DioHttpService implements HttpService {
  /// [createAdapter]:代理换代后用来换掉底层连接的工厂。不给时:自己建的 [Dio]
  /// 用 dart:io 的默认适配器;调用方传进来的 [dio] 适配器归调用方管,不替换。
  DioHttpService([Dio? dio, HttpClientAdapter Function()? createAdapter])
      : _dio = dio ?? Dio(),
        _createAdapter =
            createAdapter ?? (dio == null ? IOHttpClientAdapter.new : null),
        _generation = AppProxy.generation;

  final Dio _dio;
  final HttpClientAdapter Function()? _createAdapter;

  /// 当前适配器是在哪个代理世代下建的(见 [AppProxy.generation])。
  int _generation;

  @override
  Future<HostResponse> fetch(HostRequest request) =>
      _fetch(request, allowProxyRetry: true);

  /// 代理换代了就换一个新的适配器(连同它里面的 `HttpClient`)。
  ///
  /// dio 的 [IOHttpClientAdapter] 第一次请求时建一个 `HttpClient` 然后一直复用,
  /// 而 `HttpClient` 只在构造那一刻读 [HttpOverrides.global](见
  /// [AppProxy.generation])。不换的话,[AppProxy.retryDetect] 探到的代理对这个
  /// service 永远不生效——下面那次「重试」照样直连,等于白探。图片缓存
  /// (`ProxyAwareImageService`)是同一个做法。
  void _followProxyGeneration() {
    final generation = AppProxy.generation;
    if (generation == _generation) return;
    _generation = generation;
    final create = _createAdapter;
    if (create == null) return;
    final old = _dio.httpClientAdapter;
    _dio.httpClientAdapter = create();
    // 不 force:旧连接上还没结束的请求让它跑完,之后自然释放
    old.close();
  }

  Future<HostResponse> _fetch(
    HostRequest request, {
    required bool allowProxyRetry,
  }) async {
    _followProxyGeneration();
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
