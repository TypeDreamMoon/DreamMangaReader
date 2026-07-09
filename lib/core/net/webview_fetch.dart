import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../log/app_log.dart';
import '../source/source.dart';

/// 判断当前 HTML 是否仍是「拦截门页」而非真内容 —— 用于**越门轮询**。
///
/// 很多站点(樱花 yhdmp、风车 dm530、CF 挑战…)首帧返回一个短小的门页:
/// `setTimeout` + `document.cookie` + `window.location` 跳转 / DOM 原地替换,
/// 真实浏览器几百 ms 后就换成真内容。裸抓 `onLoadStop` 抢在跳转前,只拿到门页。
/// 门页特征:**短**且含跳转/挑战标记。真内容页通常远大于门页,快速判否、零额外开销。
bool _looksLikeGate(String html) {
  if (html.isEmpty) return true;
  if (html.length > 12000) return false; // 真内容页几乎都远大于门页
  final low = html.toLowerCase();
  const markers = [
    'redirecting', // yhdmp 门页 <title>Redirecting...</title>
    'just a moment', // CF 挑战
    'checking your browser', // CF / DDoS 盾
    'challenge-platform', 'cf-chl', 'jschl', '_cf_chl', // CF 挑战脚本
    'ddos-guard', 'please wait', 'enable javascript',
    '系统安全验证', // 苹果CMS mac_verify 门(acgbibi 搜索)
    '正在跳转', '请稍候', '稍等',
  ];
  for (final m in markers) {
    if (low.contains(m)) return true;
  }
  return false;
}

/// 越门:反复取 HTML 直到不再像门页(跳转/替换完成)或到上限。
/// 非门页首取即返回(与旧行为一致,不拖慢 mhgm/copy 等正常源)。
Future<String> _grabPastGate(
  Future<String> Function() grab,
  Duration settle,
) async {
  String html = '';
  for (var tries = 0; tries < 16; tries++) {
    await Future<void>.delayed(settle);
    html = await grab();
    if (!_looksLikeGate(html)) break; // 真内容,收工
  }
  return html; // 到上限仍像门页也返回(交给上层兜底)
}

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
    var started = false; // 门页跳转会二次触发 onLoadStop,只让首帧启动越门轮询

    headless = HeadlessInAppWebView(
      webViewEnvironment: env,
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        userAgent: userAgent,
        javaScriptEnabled: true,
        // Cloudflare 挑战靠 DOM 存储(localStorage)存状态 + 第三方 cookie 接 cf_clearance;
        // 缺了这些挑战 JS 跑不完,永远停在门页(Android 尤其明显)。一并开数据库存储。
        domStorageEnabled: true,
        databaseEnabled: true,
        thirdPartyCookiesEnabled: true,
      ),
      onLoadStop: (controller, u) async {
        if (started) return;
        started = true;
        try {
          // 每轮取一次 HTML:raw 走同源 fetch(含 packer 脚本),否则取 JS 渲染后的 DOM。
          // 轮询直到越过门页(见 [_grabPastGate]):门页跳转/替换后 getHtml 才是真内容。
          final html = await _grabPastGate(() async {
            if (raw) {
              // raw:用页面自身 origin 的 fetch 取“原始 HTML”(含 packer 脚本,不 403)。
              // 章节页用它(packer 只在原始 HTML 里,JS 跑完就没了)。
              try {
                final res = await controller.callAsyncJavaScript(
                  functionBody:
                      "var r = await fetch(window.location.href, {credentials:'include', headers: h || {}}); return await r.text();",
                  arguments: {'h': headers ?? const <String, String>{}},
                );
                final s = (res?.value ?? '').toString();
                if (s.isNotEmpty) return s;
              } catch (_) {}
            }
            // 默认:取 JS 渲染后的 DOM —— 详情页的章节列表、发现页都靠 JS 渲染。
            return await controller.getHtml() ?? '';
          }, settle);
          if (!completer.isCompleted) completer.complete(html);
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      // 门页跳转(window.location.replace)会中止当前加载 → 触发本回调「connection stopped」。
      // 只要越门轮询已启动(started),这类中止是**预期**的,忽略即可,让轮询抓跳转后的真页;
      // 仅在轮询启动前(首帧就失败)才当真报错。
      onReceivedError: (controller, request, error) {
        if (!started && !completer.isCompleted) {
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
    var started = false; // 门页跳转会二次触发 onLoadStop,只让首帧启动越门轮询

    headless = HeadlessInAppWebView(
      webViewEnvironment: env,
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        userAgent: userAgent,
        javaScriptEnabled: true,
        // Cloudflare 挑战靠 DOM 存储(localStorage)存状态 + 第三方 cookie 接 cf_clearance;
        // 缺了这些挑战 JS 跑不完,永远停在门页(Android 尤其明显)。一并开数据库存储。
        domStorageEnabled: true,
        databaseEnabled: true,
        thirdPartyCookiesEnabled: true,
      ),
      onLoadStop: (controller, u) async {
        if (started) return;
        started = true;
        try {
          // 先越门:门页里 pageJs 跑的是门页上下文(拿不到真数据),等换成真内容再执行。
          await _grabPastGate(() async => await controller.getHtml() ?? '', settle);
          // callAsyncJavaScript 支持 await/Promise(jsSource 是 async 函数体,用 return 返回)。
          final res = await controller.callAsyncJavaScript(functionBody: jsSource);
          final out = res?.value ?? res?.error ?? '(null)';
          if (!completer.isCompleted) completer.complete(out);
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      // 见 fetchHtml:越门轮询启动后,跳转导致的加载中止是预期的,忽略。
      onReceivedError: (controller, request, error) {
        if (!started && !completer.isCompleted) {
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
    final sw = Stopwatch()..start();
    final mode = request.pageJs != null ? 'WebView·JS' : 'WebView';
    try {
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
        sw.stop();
        final body = '${out ?? ''}';
        logHttp(mode, request.url, 200, body.length, sw.elapsedMilliseconds);
        return HostResponse(status: 200, headers: const {}, body: body);
      }
      final html = await WebViewFetcher.fetchHtml(
        request.url,
        userAgent: userAgent ?? request.headers['User-Agent'],
        raw: request.rawHtml,
        headers: request.headers,
      );
      sw.stop();
      logHttp(mode, request.url, 200, html.length, sw.elapsedMilliseconds);
      return HostResponse(status: 200, headers: const {}, body: html);
    } catch (e) {
      sw.stop();
      logHttpError(mode, request.url, sw.elapsedMilliseconds, e);
      rethrow;
    }
  }
}
