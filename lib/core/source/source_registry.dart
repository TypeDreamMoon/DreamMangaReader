import '../net/dio_http_service.dart';
import '../net/webview_fetch.dart';
import '../script/js_engine.dart';
import '../script/script_source.dart';
import 'source.dart';

/// 通用移动端 UA(WebView 与后续图片请求共用;不针对任何具体站点)。
const String _mobileUa =
    'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

/// 通用桌面 UA(需要网页端 WebView 的源用;与常规浏览器一致)。
const String _desktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';

/// 一个脚本源的元数据。**引擎不内置任何具体源**——[registeredSources] 由
/// [SourceRepository] 在启动时从外部清单(index.json + 脚本)加载填充。
class SourceMeta {
  const SourceMeta({
    required this.id,
    required this.name,
    required this.script,
    this.experimental = false,
    this.useWebView = false, // 站点拦裸 HTTP 时走隐藏 WebView 抓取
    this.imageReferer, // 图片(封面/页面)加载所需的 Referer
    this.needsLogin = false, // 该源内容需账号登录(脚本实现 prepareLogin/handleLogin)
  });

  /// 从清单条目 + 已取到的脚本正文构建。脚本正文单独拉取(清单里只存文件名)。
  factory SourceMeta.fromJson(Map<String, dynamic> j, {required String script}) =>
      SourceMeta(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? j['id'] as String,
        script: script,
        experimental: (j['experimental'] as bool?) ?? false,
        useWebView: (j['useWebView'] as bool?) ?? false,
        imageReferer: j['imageReferer'] as String?,
        needsLogin: (j['needsLogin'] as bool?) ?? false,
      );

  final String id;
  final String name;
  final String script;
  final bool experimental;
  final bool useWebView;
  final String? imageReferer;
  final bool needsLogin;
}

/// 加载该源图片(封面/页面)时要带的头(通常是 Referer,防盗链)。
Map<String, String> imageHeadersOf(SourceMeta m) =>
    m.imageReferer == null ? const {} : {'Referer': m.imageReferer!};

/// 源 id → 展示名(卡片角标用);未知 id 原样返回。
String sourceNameOf(String id) {
  for (final m in registeredSources) {
    if (m.id == id) return m.name;
  }
  return id;
}

/// 运行时加载的源列表。启动前为空;由 [SourceRepository.load] 从外部清单填充。
/// 引擎仓库本身不携带任何源脚本 —— 未配置源仓库时这里就是空的。
List<SourceMeta> registeredSources = <SourceMeta>[];

/// 用注册脚本构建一个可用的 [MangaSource]。
/// - 主传输:useWebView 的源用隐藏 WebView 抓 HTML(过反爬),否则用 dio。
/// - webHttp:总是配一个 WebView 传输,供源脚本按请求切换(部分源发现走 dio、
///   章节/图片走 WebView 带站点 cookie)。
MangaSource buildSource(SourceMeta meta) => ScriptSource(
      engine: JsEngine(),
      http: meta.useWebView
          ? WebViewHttpService(userAgent: _mobileUa)
          : DioHttpService(),
      webHttp: WebViewHttpService(userAgent: _desktopUa),
      scriptCode: meta.script,
    );
