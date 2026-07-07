import 'models.dart';

/// 宿主注入给源的能力集合。源**只能**通过它接触外界(网络/解析/存储),
/// 自身没有环境权限——这是沙箱脚本源的安全基础。P0 先定接口。
abstract class HostApi {
  HttpService get http;
  void log(String level, String message);
}

/// 一个请求描述(源只描述请求,不执行 I/O)。
class HostRequest {
  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final Duration timeout;

  /// WebView 抓取时取“原始 HTML”(页面内 fetch)而非 JS 渲染后的 DOM。
  /// 章节页需要(packer 脚本只在原始 HTML 里,JS 跑完就没了)。
  final bool rawHtml;

  /// WebView 专用:加载 [url] 后**在页面上下文里执行这段 async JS**,用它的
  /// 返回字符串当响应体。给「需要站点 cookie + 同源 fetch + 读页面内全局密钥」的
  /// 场景用——比裸 dio/原始 HTML 都强。为空则走常规抓取。
  final String? pageJs;

  const HostRequest(
    this.url, {
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.timeout = const Duration(seconds: 15),
    this.rawHtml = false,
    this.pageJs,
  });
}

class HostResponse {
  final int status;
  final Map<String, String> headers;
  final String body;

  const HostResponse({
    required this.status,
    required this.headers,
    required this.body,
  });
}

/// 宿主拥有的 HTTP 层(cookie / TLS / 每源 Referer / 过盾 cookie 注入都在这实现)。
abstract class HttpService {
  Future<HostResponse> fetch(HostRequest request);
}

/// 一个漫画源要实现的契约。对应参考项目 6 组 prepare*/handle*,这里折叠为 async 方法;
/// I/O 一律走 [HostApi.http](宿主执行)。抽象方法不带默认值(Dart 限制),
/// 可选命名参数用可空,实现里兜底默认。
abstract class MangaSource {
  String get id; // 固定 slug,一经发布永不变
  String get name;
  String get lang;
  String get baseUrl;
  int get version; // 改逻辑就 +1,驱动仓库更新
  bool get nsfw;

  /// 该源支持的浏览筛选维度(地区/剧情/排序…),发现页据此渲染筛选条。
  /// 默认空 = 不支持筛选浏览。
  List<FilterDef> get filters => const [];

  /// 站点特化板块(排行榜/连载/完结/漫画大全…)。默认空 = 无浏览板块。
  List<SourceSection> get sections => const [];

  /// 拉取某板块第 [page] 页。默认不支持(返回空)。
  Future<Paged<Manga>> getSection(String sectionId, int page) async =>
      const Paged<Manga>([]);

  Future<Paged<Manga>> getDiscovery(int page, {Map<String, Object?>? filters});
  Future<Paged<Manga>> getSearch(String query, int page,
      {Map<String, Object?>? filters});
  Future<Manga> getMangaDetail(String mangaId);
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page});
  Future<List<PageImage>> getPages(String mangaId, String chapterId);

  /// 番剧一集的可播放视频源(清晰度 / 线路列表)。仅番剧源(meta.kind='anime')实现,
  /// 默认不支持。参数复用漫画契约:animeId 即 mangaId、episodeId 即 chapterId
  /// (番剧沿用 discovery/search/detail/chapters,仅把 getPages 换成本方法)。
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) async =>
      throw UnsupportedError('该源不支持视频播放');

  /// 源自带登录(可选)。默认不支持;需要账号的源在脚本里实现 prepareLogin/handleLogin,
  /// 用账号密码换回 token。登录协议(host/端点/编码)全在源脚本里,引擎不感知具体站点。
  Future<SourceLogin> login(String username, String password) async =>
      throw UnsupportedError('该源不支持登录');

  /// 释放资源(如 JS 引擎)。默认空实现。
  void dispose() {}
}

/// 源登录结果:token(必填)+ 可选昵称。
class SourceLogin {
  const SourceLogin({required this.token, this.nickname});
  final String token;
  final String? nickname;
}

/// 一个最简 [HostApi] 实现,用于 P0 联调。
class DefaultHostApi implements HostApi {
  DefaultHostApi(this.http);

  @override
  final HttpService http;

  @override
  void log(String level, String message) {
    // ignore: avoid_print
    print('[source:$level] $message');
  }
}
