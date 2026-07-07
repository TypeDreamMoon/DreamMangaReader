import 'dart:convert';

import '../source/auth_token.dart';
import '../source/models.dart';
import '../source/source.dart';
import 'crypto_host.dart';
import 'html_host.dart';
import 'js_engine.dart';
import 'lz_host.dart';

/// 用一段 JS 脚本(实现 `prepare*/handle*` 契约)+ 宿主编排,落地一个 [MangaSource]。
///
/// 核心思想:**宿主拥有全部 I/O**。
/// 流程:Dart 调 JS 的 `prepare*` 拿到"请求描述" → dio 执行 → 调 JS 的 `handle*(响应文本)` 解析。
/// JS 侧是纯函数(字符串进、结构化数据出),不做任何网络访问——这也是它能被沙箱化、
/// 跨 Android/Windows、且能远程热更的根本原因。
///
/// 约定:脚本把源对象挂到 `globalThis.__source`,形如:
/// ```js
/// var __source = {
///   meta: { id, name, lang, baseUrl, version, nsfw },
///   prepareDiscovery(page, filters) { return { url, method, headers, body }; },
///   handleDiscovery(text) { return [ { id, title, cover, authors, ... } ]; },
///   // prepareSearch/handleSearch, prepareMangaInfo/handleMangaInfo,
///   // prepareChapterList/handleChapterList, prepareChapter/handleChapter …
/// };
/// ```
class ScriptSource implements MangaSource {
  ScriptSource({
    required JsEngine engine,
    required HttpService http,
    required String scriptCode,
    HttpService? webHttp,
  })  : _js = engine,
        _http = http,
        _webHttp = webHttp {
    _html = HtmlHost(_js); // 注入 host.html.*(供源脚本解析 HTML)
    LzHost(_js); // 注入 host.lz.*(lz-string 解包,部分源的压缩页表用)
    CryptoHost(_js); // 注入 host.crypto.*(md5/AES/HMAC,API 型源用)
    _js.evalSync(scriptCode);
    final meta = jsonDecode(_js.evalSync('JSON.stringify(__source.meta)'))
        as Map<String, dynamic>;
    id = meta['id'] as String;
    name = meta['name'] as String;
    lang = (meta['lang'] as String?) ?? 'zh-Hans';
    baseUrl = (meta['baseUrl'] as String?) ?? '';
    version = (meta['version'] as num?)?.toInt() ?? 1;
    nsfw = (meta['nsfw'] as bool?) ?? false;
    _filters = _parseFilters();
    _sections = _parseSections();
  }

  /// 只解析脚本的 `__source.meta`(不建传输、不联网),用于「添加本地单文件源」时读取
  /// id/name 等元信息,并顺便验证脚本能被 eval。语法错 / 无 `__source` 会抛异常。
  static Map<String, dynamic> readMeta(String scriptCode) {
    final js = JsEngine();
    HtmlHost(js);
    LzHost(js);
    CryptoHost(js);
    try {
      js.evalSync(scriptCode);
      return jsonDecode(js.evalSync('JSON.stringify(__source.meta)'))
          as Map<String, dynamic>;
    } finally {
      js.dispose();
    }
  }

  /// 从脚本读取 `__source.sections`(可选),供浏览页渲染板块 tab。
  List<SourceSection> _parseSections() {
    final raw = _js.evalSync(
        "typeof __source.sections !== 'undefined' ? JSON.stringify(__source.sections) : 'null'");
    if (raw == 'null' || raw.isEmpty) return const [];
    final list = jsonDecode(raw) as List;
    return [
      for (final s in list.cast<Map<String, dynamic>>())
        SourceSection(
            id: (s['id'] as String?) ?? '', name: (s['name'] as String?) ?? ''),
    ];
  }

  /// 从脚本读取 `__source.filters`(可选),供发现页渲染筛选条。
  List<FilterDef> _parseFilters() {
    final raw = _js.evalSync(
        "typeof __source.filters !== 'undefined' ? JSON.stringify(__source.filters) : 'null'");
    if (raw == 'null' || raw.isEmpty) return const [];
    final list = jsonDecode(raw) as List;
    return [
      for (final f in list.cast<Map<String, dynamic>>())
        FilterDef(
          id: f['id'] as String,
          label: (f['label'] as String?) ?? '',
          type: (f['type'] as String?) ?? 'select',
          options: [
            for (final o in ((f['options'] as List?) ?? const [])
                .cast<Map<String, dynamic>>())
              (value: (o['value'] as String?) ?? '', label: (o['label'] as String?) ?? '')
          ],
        ),
    ];
  }

  final JsEngine _js;
  final HttpService _http;

  /// 可选的 WebView 传输:源脚本某个请求返回 `{ webview: true }` 时用它(带站点
  /// cookie / 系统代理 / 页面内 JS)。某些源=发现走 dio,章节/图片走这个。
  final HttpService? _webHttp;
  late final HtmlHost _html;

  @override
  late final String id;
  @override
  late final String name;
  @override
  late final String lang;
  @override
  late final String baseUrl;
  @override
  late final int version;
  @override
  late final bool nsfw;

  late final List<FilterDef> _filters;
  @override
  List<FilterDef> get filters => _filters;

  late final List<SourceSection> _sections;
  @override
  List<SourceSection> get sections => _sections;

  /// prepare(JS,同步) → fetch(dio,异步) → handle(JS,同步)。
  Future<T> _run<T>(
    String prepareFn,
    List<Object?> prepareArgs,
    String handleFn,
    T Function(Object? json) decode,
  ) async {
    // 每次运行前把该源当前登录 token 注入 JS 全局,需要登录的源据此给请求带 Authorization。
    // 源脚本是纯函数沙箱、拿不到 App 状态,这是喂「登录态」进去的唯一通道。
    _js.evalSync(
        'globalThis.__sourceToken = ${jsonEncode(SourceAuth.tokenFor(id) ?? '')};');

    final reqJson = _js.evalSync(
      'JSON.stringify(__source.$prepareFn(${_encodeArgs(prepareArgs)}))',
    );
    final req = jsonDecode(reqJson) as Map<String, dynamic>;

    // 传输选择:req.webview==true 且注入了 WebView 服务 → 走 WebView(cookie/代理/
    // 页面内 JS);否则走主传输(通常 dio)。
    final web = _webHttp;
    final service = (req['webview'] == true && web != null) ? web : _http;

    final resp = await service.fetch(HostRequest(
      req['url'] as String,
      method: (req['method'] as String?) ?? 'GET',
      headers: (req['headers'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
      body: req['body'] as String?,
      rawHtml: req['raw'] == true,
      pageJs: req['pageJs'] as String?,
    ));

    // 把响应体作为 JSON 字符串字面量安全注入(jsonEncode 负责转义),
    // 并把 prepare 的参数(mangaId/chapterId 等)接在后面 —— handleChapterList/
    // handleMangaInfo 需要 mangaId;多余参数 JS 会忽略。
    final handleTail =
        prepareArgs.isEmpty ? '' : ', ${_encodeArgs(prepareArgs)}';
    final outJson = _js.evalSync(
      'JSON.stringify(__source.$handleFn(${jsonEncode(resp.body)}$handleTail))',
    );
    _html.reset(); // 清空本次解析产生的节点 id 表
    return decode(jsonDecode(outJson));
  }

  String _encodeArgs(List<Object?> args) => args.map(jsonEncode).join(', ');

  @override
  Future<Paged<Manga>> getDiscovery(int page, {Map<String, Object?>? filters}) =>
      _run('prepareDiscovery', [page, filters ?? {}], 'handleDiscovery', (j) {
        final items = _mangaList(j);
        return Paged(items, hasNext: items.isNotEmpty); // 有内容就假定还有下一页
      });

  @override
  Future<Paged<Manga>> getSection(String sectionId, int page) =>
      // 板块页与发现页同为漫画卡列表 → 复用 handleDiscovery 解析。
      _run('prepareSection', [sectionId, page], 'handleDiscovery', (j) {
        final items = _mangaList(j);
        return Paged(items, hasNext: items.isNotEmpty);
      });

  @override
  Future<Paged<Manga>> getSearch(String query, int page,
          {Map<String, Object?>? filters}) =>
      _run('prepareSearch', [query, page, filters ?? {}], 'handleSearch',
          (j) => Paged(_mangaList(j)));

  @override
  Future<Manga> getMangaDetail(String mangaId) => _run(
        'prepareMangaInfo',
        [mangaId],
        'handleMangaInfo',
        (j) => _toManga((j as Map).cast<String, dynamic>()),
      );

  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) => _run(
        'prepareChapterList',
        [mangaId, page ?? 1],
        'handleChapterList',
        (j) => Paged([
          for (final m in (j as List).cast<Map<String, dynamic>>())
            _toChapter(m),
        ]),
      );

  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) => _run(
        'prepareChapter',
        [mangaId, chapterId],
        'handleChapter',
        (j) => [
          for (final m in (j as List).cast<Map<String, dynamic>>())
            PageImage(index: m['index'] as int, url: m['url'] as String),
        ],
      );

  @override
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) => _run(
        'prepareVideo',
        [animeId, episodeId],
        'handleVideo',
        (j) => [
          for (final m in (j as List).cast<Map<String, dynamic>>())
            VideoTrack(
              url: m['url'] as String,
              quality: (m['quality'] as String?) ?? '',
              headers: (m['headers'] as Map?)?.map(
                  (k, v) => MapEntry(k.toString(), v.toString())),
              hls: (m['hls'] as bool?) ??
                  (m['url'] as String).contains('.m3u8'),
            ),
        ],
      );

  @override
  Future<SourceLogin> login(String username, String password) async {
    final has = _js.evalSync("typeof __source.prepareLogin === 'function'");
    if (has != 'true') throw UnsupportedError('该源不支持登录');
    // 登录复用 prepare/handle 契约:prepareLogin(u,p)→请求描述,handleLogin(响应)→{token,nickname,error}。
    return _run('prepareLogin', [username, password], 'handleLogin', (j) {
      final m = (j as Map).cast<String, dynamic>();
      final err = m['error']?.toString();
      if (err != null && err.isNotEmpty) throw Exception(err);
      final token = m['token']?.toString() ?? '';
      if (token.isEmpty) throw Exception('登录失败:未拿到 token');
      return SourceLogin(token: token, nickname: m['nickname']?.toString());
    });
  }

  @override
  void dispose() => _js.dispose();

  List<Manga> _mangaList(Object? j) =>
      [for (final m in (j as List).cast<Map<String, dynamic>>()) _toManga(m)];

  Manga _toManga(Map<String, dynamic> m) => Manga(
        id: m['id'] as String,
        title: (m['title'] as String?) ?? '',
        url: m['url'] as String?,
        cover: m['cover'] as String?,
        authors: (m['authors'] as List?)?.cast<String>() ?? const [],
        genres: (m['genres'] as List?)?.cast<String>() ?? const [],
        description: m['description'] as String?,
        status: _parseStatus(m['status'] as String?),
      );

  MangaStatus _parseStatus(String? s) {
    switch (s) {
      case 'ongoing':
        return MangaStatus.ongoing;
      case 'completed':
        return MangaStatus.completed;
      case 'hiatus':
        return MangaStatus.hiatus;
      case 'cancelled':
        return MangaStatus.cancelled;
      default:
        return MangaStatus.unknown;
    }
  }

  Chapter _toChapter(Map<String, dynamic> m) => Chapter(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        url: m['url'] as String?,
        number: (m['number'] as num?)?.toDouble(),
      );
}
