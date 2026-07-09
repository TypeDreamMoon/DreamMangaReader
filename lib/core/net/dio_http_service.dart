import 'package:dio/dio.dart';

import '../log/app_log.dart';
import '../source/source.dart';

/// [HttpService] 的 dio 实现。P0 为基础版;后续接:
/// - cookie jar(cookie_jar / dio_cookie_manager)
/// - 每源 UA / Referer 拦截器
/// - 过盾:把 WebView 取到的 cf_clearance 注入这里
/// - 限速 / 429 退避
class DioHttpService implements HttpService {
  DioHttpService([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<HostResponse> fetch(HostRequest request) async {
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
      rethrow;
    }
  }
}
