import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../source/source.dart';

/// 通过**隐藏 WebView** 抓取页面 HTML —— 绕过 nginx / anti-bot / Cloudflare 对裸 HTTP 的拦截。
///
/// 背景:部分站点对裸 dio 请求返回 403,但浏览器/WebView 能正常加载。
/// WebView 带真实浏览器指纹 + 会自动过 CF 挑战,是最稳的抓取方式。
class WebViewFetcher {
  static WebViewEnvironment? _env;
  static bool _envInit = false;

  static Future<WebViewEnvironment?> _environment() async {
    if (_envInit) return _env;
    _envInit = true;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final dir = await getApplicationSupportDirectory();
      _env = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: '${dir.path}\\webview2_fetch',
        ),
      );
    }
    return _env;
  }

  /// 在隐藏 WebView 里加载 [url],等页面稳定后返回其 HTML。
  static Future<String> fetchHtml(
    String url, {
    String? userAgent,
    bool raw = false,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
    Duration settle = const Duration(milliseconds: 700),
  }) async {
    final env = await _environment();
    final completer = Completer<String>();
    HeadlessInAppWebView? headless;

    headless = HeadlessInAppWebView(
      webViewEnvironment: env,
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        userAgent: userAgent,
        javaScriptEnabled: true,
      ),
      onLoadStop: (controller, u) async {
        try {
          await Future<void>.delayed(settle);
          String html = '';
          if (raw) {
            // raw:用页面自身 origin 的 fetch 取“原始 HTML”(含 packer 脚本,不 403)。
            // 章节页用它(packer 只在原始 HTML 里,JS 跑完就没了)。
            try {
              final res = await controller.callAsyncJavaScript(
                functionBody:
                    "var r = await fetch(window.location.href, {credentials:'include', headers: h || {}}); return await r.text();",
                arguments: {'h': headers ?? const <String, String>{}},
              );
              html = (res?.value ?? '').toString();
            } catch (_) {}
          }
          // 默认:取 JS 渲染后的 DOM —— 详情页的章节列表、发现页都靠 JS 渲染。
          if (html.isEmpty) html = await controller.getHtml() ?? '';
          if (!completer.isCompleted) completer.complete(html);
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      onReceivedError: (controller, request, error) {
        if (!completer.isCompleted) {
          completer.completeError('WebView error: ${error.description}');
        }
      },
    );

    await headless.run();
    try {
      return await completer.future.timeout(timeout);
    } finally {
      await headless.dispose();
    }
  }

  /// 在隐藏 WebView 里加载 [url],等页面 JS 跑完后**执行 [jsSource] 并返回结果**。
  /// 用于"JS 跑完把数据留在内存变量"这类页面(直接读整章图片列表,
  /// 连 LZString 解码都省了——WebView 已替我们解好)。
  static Future<Object?> evalInPage(
    String url,
    String jsSource, {
    String? userAgent,
    Duration timeout = const Duration(seconds: 30),
    Duration settle = const Duration(milliseconds: 800),
  }) async {
    final env = await _environment();
    final completer = Completer<Object?>();
    HeadlessInAppWebView? headless;

    headless = HeadlessInAppWebView(
      webViewEnvironment: env,
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        userAgent: userAgent,
        javaScriptEnabled: true,
      ),
      onLoadStop: (controller, u) async {
        try {
          await Future<void>.delayed(settle);
          // callAsyncJavaScript 支持 await/Promise(jsSource 是 async 函数体,用 return 返回)。
          final res = await controller.callAsyncJavaScript(functionBody: jsSource);
          final out = res?.value ?? res?.error ?? '(null)';
          if (!completer.isCompleted) completer.complete(out);
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      onReceivedError: (controller, request, error) {
        if (!completer.isCompleted) {
          completer.completeError('WebView error: ${error.description}');
        }
      },
    );

    await headless.run();
    try {
      return await completer.future.timeout(timeout);
    } finally {
      await headless.dispose();
    }
  }
}

/// [HttpService] 的 WebView 实现:GET 页面 HTML 走隐藏 WebView(用于被反爬拦截的源)。
/// 仅返回 HTML 文本;图片抓取仍走 dio(带 WebView 取到的 cookie)。
class WebViewHttpService implements HttpService {
  WebViewHttpService({this.userAgent});

  final String? userAgent;

  @override
  Future<HostResponse> fetch(HostRequest request) async {
    // pageJs:加载页面后在其上下文执行脚本,返回值即响应体(需同源 fetch/读页面密钥的源用)。
    if (request.pageJs != null) {
      final out = await WebViewFetcher.evalInPage(
        request.url,
        request.pageJs!,
        userAgent: userAgent ?? request.headers['User-Agent'],
        timeout: request.timeout < const Duration(seconds: 20)
            ? const Duration(seconds: 30)
            : request.timeout,
      );
      return HostResponse(status: 200, headers: const {}, body: '${out ?? ''}');
    }
    final html = await WebViewFetcher.fetchHtml(
      request.url,
      userAgent: userAgent ?? request.headers['User-Agent'],
      raw: request.rawHtml,
      headers: request.headers,
    );
    return HostResponse(status: 200, headers: const {}, body: html);
  }
}
