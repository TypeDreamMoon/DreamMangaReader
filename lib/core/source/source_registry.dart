import '../bili/bili_source.dart';
import '../net/dio_http_service.dart';
import '../net/webview_fetch.dart';
import '../novel/novel_source.dart';
import '../script/js_engine.dart';
import '../script/script_source.dart';
import 'source.dart';

/// 内置(非脚本)原生源 id。这些源由引擎直接实现,不从仓库脚本加载。
const String kBiliSourceId = 'bilibili';

/// 内置源 id 集合。这些 id 在 [SourceMeta.credentialKey] 里当保留字处理 ——
/// 详见 [SourceMeta.credentialKey]。
const Set<String> kBuiltInSourceIds = {kBiliSourceId};

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
    this.kind = 'manga', // 'manga' | 'anime' | 'novel' —— 决定按内容类型分档
    this.experimental = false,
    this.useWebView = false, // 站点拦裸 HTTP 时走隐藏 WebView 抓取
    this.imageReferer, // 图片(封面/页面)加载所需的 Referer
    this.needsLogin = false, // 该源内容需账号登录(脚本实现 prepareLogin/handleLogin)
    this.authKey, // 多个源可共用同一份登录凭据;未设置时使用 id
  });

  /// 从清单条目 + 已取到的脚本正文构建。脚本正文单独拉取(清单里只存文件名)。
  factory SourceMeta.fromJson(Map<String, dynamic> j, {required String script}) =>
      SourceMeta(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? j['id'] as String,
        script: script,
        kind: (j['kind'] as String?) ?? 'manga',
        experimental: (j['experimental'] as bool?) ?? false,
        useWebView: (j['useWebView'] as bool?) ?? false,
        imageReferer: j['imageReferer'] as String?,
        needsLogin: (j['needsLogin'] as bool?) ?? false,
        authKey: j['authKey'] as String?,
      );

  final String id;
  final String name;
  final String script;

  /// 内容类型:'manga'(默认)、'anime'(番剧)或 'novel'(小说)。
  final String kind;
  bool get isAnime => kind == 'anime';
  bool get isNovel => kind == 'novel';
  bool get isManga => kind == 'manga';

  final bool experimental;
  final bool useWebView;
  final String? imageReferer;
  final bool needsLogin;
  final String? authKey;

  /// 该源用哪份登录凭据。多个源可通过 [authKey] 共用一份(晓桀的漫画/小说/番剧三源
  /// 共用一个 GitHub token)。
  ///
  /// 但 [authKey] 来自远程仓库清单,而清单内容不受本应用控制:如果放任它取任意值,
  /// 清单里任何一个脚本源只要声明 `"authKey": "bilibili"`,就能让引擎把用户的 B 站
  /// 凭据注入自己的脚本上下文。所以内置源 id 一律按保留字处理 —— 只有内置源自己能用。
  ///
  /// 脚本源之间的共用不受限制:它们都来自同一个用户配置的仓库,属同一信任域。
  String get credentialKey {
    final key = authKey;
    if (key == null || key.isEmpty) return id;
    if (key != id && kBuiltInSourceIds.contains(key)) return id;
    return key;
  }
}

/// 加载该源图片(封面/页面)时要带的头(通常是 Referer,防盗链)。
Map<String, String> imageHeadersOf(SourceMeta m) =>
    m.imageReferer == null ? const {} : {'Referer': m.imageReferer!};

/// 源 id → 展示名(卡片角标用);未知 id 原样返回。
String sourceNameOf(String id) => sourceMetaById(id)?.name ?? id;

/// 源 id → 元信息;源被删/未加载时为 null(调用方据此走「换源打开」或降级)。
SourceMeta? sourceMetaById(String id) {
  for (final m in registeredSources) {
    if (m.id == id) return m;
  }
  return null;
}

/// 该源的图片请求头;源已不存在(id 未注册)时返回空表。
Map<String, String> imageHeadersFor(String? sourceId) {
  if (sourceId == null) return const {};
  final meta = sourceMetaById(sourceId);
  return meta == null ? const {} : imageHeadersOf(meta);
}

/// 运行时加载的源列表。启动前为空;由 [SourceRepository.load] 从外部清单填充。
/// 引擎仓库本身不携带任何源脚本 —— 未配置源仓库时这里就是空的。
List<SourceMeta> registeredSources = <SourceMeta>[];

/// 用注册脚本构建一个可用的 [MangaSource]。
/// - 主传输:useWebView 的源用隐藏 WebView 抓 HTML(过反爬),否则用 dio。
/// - webHttp:总是配一个 WebView 传输,供源脚本按请求切换(部分源发现走 dio、
///   章节/图片走 WebView 带站点 cookie)。
MangaSource buildSource(SourceMeta meta) {
  // 原生番剧源(B站):走引擎内置实现,不经脚本引擎。
  if (meta.id == kBiliSourceId) return BiliSource();
  // 与 buildNovelSource 对称拦一道:两个接口复用同一批 JS 入口
  // (prepareDiscovery/handleDiscovery 等),小说源被当漫画源用不会报错,
  // 只会解出「看起来合理但语义错误」的条目,不拦就查不出来。
  if (meta.isNovel) {
    throw ArgumentError.value(meta.kind, 'meta.kind', 'expected manga or anime');
  }
  return _buildScriptSource(meta);
}

NovelSource buildNovelSource(SourceMeta meta) {
  if (!meta.isNovel) {
    throw ArgumentError.value(meta.kind, 'meta.kind', 'expected novel');
  }
  return _buildScriptSource(meta);
}

ScriptSource _buildScriptSource(SourceMeta meta) => ScriptSource(
      engine: JsEngine(),
      http: meta.useWebView
          ? WebViewHttpService(userAgent: _mobileUa)
          : DioHttpService(),
      webHttp: WebViewHttpService(userAgent: _desktopUa),
      scriptCode: meta.script,
    );

/// 内置原生源的元数据(启动时无条件并入 [registeredSources],除非用户手动隐藏)。
const SourceMeta kBiliSourceMeta = SourceMeta(
  id: kBiliSourceId,
  name: '哔哩哔哩',
  script: '',
  kind: 'anime',
  needsLogin: true,
);
