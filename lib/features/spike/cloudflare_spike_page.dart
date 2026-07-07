import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/theme/app_colors.dart';
import '../../ui/ui.dart';

/// 经典的 Cloudflare 挑战测试站(公开、无版权内容),用于验证过盾链路。
/// 真实修源时把它换成目标漫画站的基域名。
const String _kDefaultUrl = 'https://nowsecure.nl';

/// 与 WebView 一致的 UA —— cf_clearance 与 UA 绑定,复验时**必须一致**。
const String _kUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// P0 关键门槛:证明在 Android + Windows 上都能
/// 「WebView 过挑战 → 取 cf_clearance → 交给普通 HTTP 客户端复用」。
class CloudflareSpikePage extends StatefulWidget {
  const CloudflareSpikePage({super.key});

  @override
  State<CloudflareSpikePage> createState() => _CloudflareSpikePageState();
}

class _CloudflareSpikePageState extends State<CloudflareSpikePage> {
  final TextEditingController _urlCtrl =
      TextEditingController(text: _kDefaultUrl);

  WebViewEnvironment? _env;
  CookieManager? _cookieManager;
  String _udf = '(平台默认)';
  bool _ready = false;

  InAppWebViewController? _controller;
  String _status = '初始化…';
  final StringBuffer _logBuf = StringBuffer();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _line('=== 初始化 ===');
    _line('平台: $defaultTargetPlatform');
    try {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final dir = await getApplicationSupportDirectory();
        _udf = '${dir.path}\\webview2';
        _env = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: _udf),
        );
        _line('WebViewEnvironment 已创建');
        _line('userDataFolder: $_udf');
      } else {
        _line('非 Windows,使用平台默认 cookie 存储');
      }
      _cookieManager = CookieManager.instance(webViewEnvironment: _env);
      _line('CookieManager.instance(env=${_env != null}) OK');
    } catch (e) {
      _line('初始化异常: $e');
    }
    if (mounted) {
      setState(() {
        _ready = true;
        _status = '准备就绪。点「加载」后等页面出真实内容,再点「取 cookie 并复验」。';
      });
    }
  }

  void _line(String s) {
    _logBuf.writeln(s);
    if (mounted) setState(() {});
  }

  void _load() {
    final url = WebUri(_urlCtrl.text.trim());
    _controller?.loadUrl(urlRequest: URLRequest(url: url));
    _line('\n=== 加载 $url ===');
    setState(() => _status = '加载 $url …');
  }

  String _cookieLine(Cookie c) {
    final v = '${c.value}';
    final vs = v.length <= 24 ? v : '${v.substring(0, 24)}…';
    return '  ${c.name} = $vs '
        '| domain=${c.domain} path=${c.path} '
        'httpOnly=${c.isHttpOnly} secure=${c.isSecure} session=${c.isSessionOnly}';
  }

  Future<void> _harvestAndVerify() async {
    setState(() => _busy = true);
    _line('\n=== 取 cookie + 复验 ===');
    try {
      final current = await _controller?.getUrl();
      final title = await _controller?.getTitle();
      final target = current ?? WebUri(_urlCtrl.text.trim());
      _line('当前 URL: $current');
      _line('WebView 标题: $title'
          '${(title ?? '').contains('Just a moment') ? '  ← 仍在 CF 挑战中!' : ''}');

      var cookies = await _cookieManager!.getCookies(url: target);
      _line('getCookies($target): ${cookies.length} 个');

      if (cookies.isEmpty) {
        final origin = WebUri('${target.scheme}://${target.host}');
        cookies = await _cookieManager!.getCookies(url: origin);
        _line('回退 getCookies($origin): ${cookies.length} 个');
      }

      // 汇总 cookie:CookieManager(Windows 上通常空)+ CDP(主路径)。
      final jar = <String, String>{};
      for (final c in cookies) {
        jar[c.name] = '${c.value}';
        _line(_cookieLine(c));
      }

      // ★ Windows WebView2 = CDP:直接调 Network.getAllCookies,能拿到 httpOnly 的 cf_clearance。
      try {
        final res = await _controller
            ?.callDevToolsProtocolMethod(methodName: 'Network.getAllCookies');
        final list = (res is Map ? res['cookies'] : null) as List? ?? const [];
        _line('CDP Network.getAllCookies: ${list.length} 个');
        for (final c in list) {
          if (c is! Map) continue;
          final name = '${c['name']}';
          final val = '${c['value']}';
          jar.putIfAbsent(name, () => val);
          final vs = val.length <= 24 ? val : '${val.substring(0, 24)}…';
          _line('  [cdp] $name = $vs | domain=${c['domain']} '
              'path=${c['path']} httpOnly=${c['httpOnly']} secure=${c['secure']}');
        }
      } catch (e) {
        _line('CDP Network.getAllCookies 异常: $e');
      }

      // 对照:WebView 内 document.cookie(只含非 httpOnly)
      try {
        final dc =
            await _controller?.evaluateJavascript(source: 'document.cookie');
        _line('document.cookie: $dc');
      } catch (e) {
        _line('document.cookie 异常: $e');
      }

      _line('--- 汇总 ${jar.length} 个 cookie:${jar.keys.join(', ')}');
      if (jar.containsKey('cf_clearance')) {
        _line('✓ 拿到 cf_clearance');
      } else if (jar.isEmpty) {
        _line('✗ 完全没 cookie —— 该站可能本就不设 cookie(nowsecure.nl 就是这样);'
            '请换一个真·Cloudflare 漫画站再试。');
      } else {
        _line('✗ 有 cookie 但无 cf_clearance —— 该站当时未触发 CF 挑战,或挑战未完成。');
      }

      await _verifyWithDio(jar, target.toString());
    } catch (e, st) {
      _line('异常: $e');
      _line('$st');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyWithDio(Map<String, String> jar, String url) async {
    final cookieHeader =
        jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
    _line('\n--- dio 复验 ---');
    _line('Cookie 头: ${cookieHeader.isEmpty ? '(无)' : '${cookieHeader.length} 字符'}');
    try {
      final resp = await Dio().get<String>(
        url,
        options: Options(
          headers: {
            'User-Agent': _kUserAgent,
            if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
          },
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final body = resp.data ?? '';
      final snippet =
          body.length <= 160 ? body : body.substring(0, 160);
      _line('HTTP ${resp.statusCode}, 响应 ${body.length} 字节');
      _line('响应片段: ${snippet.replaceAll('\n', ' ')}');
      final challenged = body.contains('Just a moment') ||
          body.contains('cf-browser-verification') ||
          body.contains('challenge-platform');
      _line(resp.statusCode == 200 && !challenged
          ? '✓ 普通 HTTP 通过 —— cookie 移交成功,P0 链路打通'
          : challenged
              ? '… 响应仍是 CF 挑战页(cookie 未生效/未拿到)'
              : '… HTTP ${resp.statusCode}');
    } catch (e) {
      _line('dio 复验异常: $e');
    }
  }

  void _copyLog() {
    Clipboard.setData(ClipboardData(text: _logBuf.toString()));
    showAppNotify(context, '日志已复制', kind: AppNotifyKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        title: const Text('P0 · Cloudflare 过盾验证'),
        actions: [
          IconButton(
            tooltip: '复制日志',
            onPressed: _copyLog,
            icon: const Icon(Icons.copy_all_rounded),
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _urlCtrl,
                          style: TextStyle(color: p.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '目标站点 URL',
                            filled: true,
                            fillColor: p.surface,
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: p.line),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: p.accent),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _load, child: const Text('加载')),
                    ],
                  ),
                ),
                Container(
                  height: 260,
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: p.line),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InAppWebView(
                    webViewEnvironment: _env,
                    initialUrlRequest: URLRequest(url: WebUri(_kDefaultUrl)),
                    initialSettings: InAppWebViewSettings(
                      userAgent: _kUserAgent,
                      javaScriptEnabled: true,
                      thirdPartyCookiesEnabled: true,
                    ),
                    onWebViewCreated: (c) => _controller = c,
                    onLoadStop: (c, url) async {
                      final title = await c.getTitle();
                      _line('onLoadStop: $url  (title: $title)');
                      if (mounted) {
                        setState(() => _status = '已加载:$url');
                      }
                    },
                    onReceivedError: (c, req, err) {
                      _line('onReceivedError: ${err.description}');
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _status,
                          style: TextStyle(
                              color: p.textMuted, fontSize: 11.5, height: 1.4),
                        ),
                      ),
                      FilledButton(
                        onPressed: _busy ? null : _harvestAndVerify,
                        child: Text(_busy ? '验证中…' : '取 cookie 并复验'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    color: p.surface,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(14),
                      child: SelectableText(
                        _logBuf.isEmpty ? '日志会显示在这里。' : _logBuf.toString(),
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 12,
                          height: 1.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }
}
