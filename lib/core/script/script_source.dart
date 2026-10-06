import 'dart:convert';

import 'package:meta/meta.dart';

import '../novel/models.dart';
import '../novel/novel_source.dart';
import '../source/auth_token.dart';
import '../source/models.dart';
import '../source/source.dart';
import 'crypto_host.dart';
import 'html_host.dart';
import 'js_engine.dart';
import 'lz_host.dart';

const int maxSourceContinuationRequests = 500;

/// 脚本返回值的宽松取值 helper。
///
/// 源脚本是**用户可安装的外部代码**,JS 里没有 int/String 之分:`id` 常常是数字、
/// `index` 常常是字符串。裸 `as int` / `as String` 会在解析中途以一句看不出字段名的
/// TypeError 崩掉整章。这里统一做数字/字符串互转,取不到就抛**带字段名**的
/// [FormatException] —— 与 `getNovelDocument` 的守卫风格一致,能被上层错误处理接住。
@visibleForTesting
class ScriptValues {
  const ScriptValues._();

  /// 必填字符串:数字/布尔按其字面量转,缺失或空对象抛。
  static String requireString(Map<String, dynamic> m, String field) {
    final v = optionalString(m, field);
    if (v == null) {
      throw FormatException('源返回值缺少字符串字段 `$field`(实际:${_desc(m[field])})');
    }
    return v;
  }

  /// 可选字符串:缺失 / null / 无法表示成标量时给 null。
  static String? optionalString(Map<String, dynamic> m, String field) {
    final v = m[field];
    if (v == null) return null;
    if (v is String) return v;
    if (v is num || v is bool) return '$v';
    return null;
  }

  /// 必填整数:字符串按十进制解析(`"12"` / `"12.0"` 都认),不成抛。
  static int requireInt(Map<String, dynamic> m, String field) {
    final v = optionalInt(m, field);
    if (v == null) {
      throw FormatException('源返回值缺少整数字段 `$field`(实际:${_desc(m[field])})');
    }
    return v;
  }

  static int? optionalInt(Map<String, dynamic> m, String field) =>
      optionalDouble(m, field)?.toInt();

  static double? optionalDouble(Map<String, dynamic> m, String field) {
    final v = m[field];
    if (v == null) return null;
    if (v is num) return v.isFinite ? v.toDouble() : null;
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  /// 字符串数组:整条缺失给空表;逐项宽松转换,转不动的项跳过而不是整条报废。
  static List<String> stringList(Map<String, dynamic> m, String field) {
    final v = m[field];
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is String)
          e
        else if (e is num || e is bool)
          '$e',
    ];
  }

  /// 头表:键值一律 toString;整条缺失给 null(与「不带额外头」区分开)。
  static Map<String, String>? headers(Map<String, dynamic> m, String field) {
    final v = m[field];
    if (v is! Map) return null;
    return v.map((key, value) => MapEntry(key.toString(), value.toString()));
  }

  static String _desc(Object? v) => v == null ? 'null' : '${v.runtimeType} $v';
}

/// 一次连续请求收集到的条目,外加脚本对「还有下一页」的表态(没表态 = null)。
class _Collected {
  const _Collected(this.items, this.hasNext);
  final List<Object?> items;
  final bool? hasNext;
}

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
class ScriptSource implements MangaSource, NovelSource {
  static const Map<String, int> _sourceCapabilities = {
    'collectionContinuation': 1,
  };

  /// 构造即 eval 脚本:语法错、缺 `__source.meta`、meta 字段类型不对都会在这里抛。
  /// 此时 [engine] 已经建好但还没有人持有它 —— 所以**构造失败要就地回收引擎**,
  /// 否则每打开一次坏源就漏一个 QuickJS 运行时(源列表页逐个探测时尤其明显)。
  ScriptSource({
    required JsEngine engine,
    required HttpService http,
    required String scriptCode,
    HttpService? webHttp,
  })  : _js = engine,
        _http = http,
        _webHttp = webHttp {
    try {
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
    } catch (_) {
      _js.dispose();
      rethrow;
    }
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
              (
                value: (o['value'] as String?) ?? '',
                label: (o['label'] as String?) ?? ''
              )
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
    _injectSourceContext();
    final request = _prepareRequest(prepareFn, prepareArgs);
    final response = await _fetchRequest(request);
    return decode(_handleResponse(handleFn, response, prepareArgs));
  }

  void _injectSourceContext() {
    // 源脚本是纯函数沙箱、拿不到 App 状态,每次调用前由宿主注入登录 token 和能力版本。
    _js.evalSync(
      'globalThis.__sourceToken = ${jsonEncode(SourceAuth.tokenFor(id) ?? '')};'
      'globalThis.__sourceCapabilities = '
      'Object.freeze(${jsonEncode(_sourceCapabilities)});',
    );
  }

  Map<String, dynamic> _prepareRequest(
    String prepareFn,
    List<Object?> prepareArgs,
  ) {
    final requestJson = _js.evalSync(
      'JSON.stringify(__source.$prepareFn(${_encodeArgs(prepareArgs)}))',
    );
    return (jsonDecode(requestJson) as Map).cast<String, dynamic>();
  }

  Future<HostResponse> _fetchRequest(Map<String, dynamic> request) {
    final web = _webHttp;
    final service = (request['webview'] == true && web != null) ? web : _http;
    return service.fetch(HostRequest(
      request['url'] as String,
      method: (request['method'] as String?) ?? 'GET',
      headers: (request['headers'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          const {},
      body: request['body'] as String?,
      rawHtml: request['raw'] == true,
      pageJs: request['pageJs'] as String?,
    ));
  }

  Object? _handleResponse(
    String handleFn,
    HostResponse response,
    List<Object?> prepareArgs,
  ) {
    // 把响应体作为 JSON 字符串字面量安全注入,并保留最初的 prepare 参数。
    final handleTail =
        prepareArgs.isEmpty ? '' : ', ${_encodeArgs(prepareArgs)}';
    try {
      final outputJson = _js.evalSync(
        'JSON.stringify(__source.$handleFn(${jsonEncode(response.body)}$handleTail))',
      );
      return jsonDecode(outputJson);
    } finally {
      _html.reset();
    }
  }

  /// [itemsKey] 是信封里装条目的字段名(默认 `items`);目录用 `chapters`,
  /// 两者都认。[Collected.hasNext] 是脚本对「还有下一页」的表态,没表态即 null。
  Future<_Collected> _runCollection(
    String prepareFn,
    List<Object?> prepareArgs,
    String handleFn, {
    String itemsKey = 'items',
  }) async {
    _injectSourceContext();
    var request = _prepareRequest(prepareFn, prepareArgs);
    final items = <Object?>[];
    final seenRequests = <String>{};
    bool? hasNext;

    for (var completed = 0;
        completed < maxSourceContinuationRequests;
        completed++) {
      final method = ((request['method'] as String?) ?? 'GET').toUpperCase();
      final fingerprint =
          '$method\n${request['url']}\n${request['body'] ?? ''}';
      if (!seenRequests.add(fingerprint)) {
        throw StateError('源连续请求重复，已停止以避免无限循环');
      }

      Object? output;
      try {
        output = _handleResponse(
          handleFn,
          await _fetchRequest(request),
          prepareArgs,
        );
      } catch (error) {
        if (completed == 0) rethrow;
        throw Exception('源连续请求失败（已完成 $completed 页）：$error');
      }
      if (output is List) {
        items.addAll(output);
        return _Collected(items, hasNext);
      }
      if (output is! Map) {
        throw FormatException('源连续请求必须返回数组或 {$itemsKey, next}');
      }
      final envelope = output.cast<String, dynamic>();
      final list = envelope[itemsKey] ?? envelope['items'];
      if (list is! List) {
        throw FormatException('源连续请求必须返回数组或 {$itemsKey, next}');
      }
      items.addAll(list);
      // 目录分页:脚本可在信封里表态「还有下一页」,由调用方用 page: n 逐页拉。
      final flag = envelope['hasNext'];
      if (flag is bool) hasNext = flag;
      final next = envelope['next'];
      if (next == null) return _Collected(items, hasNext);
      if (next is! Map || next['url'] is! String) {
        throw const FormatException('源连续请求的 next 不是有效请求描述');
      }
      if (completed + 1 >= maxSourceContinuationRequests) {
        throw StateError('源连续请求超过 $maxSourceContinuationRequests 次，已停止');
      }
      request = next.cast<String, dynamic>();
    }

    throw StateError('源连续请求异常终止');
  }

  String _encodeArgs(List<Object?> args) => args.map(jsonEncode).join(', ');

  @override
  Future<Paged<Manga>> getDiscovery(int page,
          {Map<String, Object?>? filters}) =>
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
          (j) {
        final items = _mangaList(j);
        return Paged(items, hasNext: items.isNotEmpty);
      });

  @override
  Future<Paged<Novel>> getNovelDiscovery(int page,
          {Map<String, Object?>? filters}) =>
      _run('prepareDiscovery', [page, filters ?? {}], 'handleDiscovery', (j) {
        final items = _novelList(j);
        return Paged(items, hasNext: items.isNotEmpty);
      });

  @override
  Future<Paged<Novel>> getNovelSection(String sectionId, int page) =>
      _run('prepareSection', [sectionId, page], 'handleDiscovery', (j) {
        final items = _novelList(j);
        return Paged(items, hasNext: items.isNotEmpty);
      });

  @override
  Future<Paged<Novel>> getNovelSearch(String query, int page,
          {Map<String, Object?>? filters}) =>
      _run('prepareSearch', [query, page, filters ?? {}], 'handleSearch',
          (j) {
        final items = _novelList(j);
        return Paged(items, hasNext: items.isNotEmpty);
      });

  @override
  Future<Novel> getNovelDetail(String novelId) => _run(
        'prepareMangaInfo',
        [novelId],
        'handleMangaInfo',
        (j) => _toNovel(_asMap(j, 'novel')),
      );

  @override
  Future<Paged<NovelChapter>> getNovelChapters(String novelId, {int? page}) =>
      _run(
        'prepareChapterList',
        [novelId, page ?? 1],
        'handleChapterList',
        (j) => Paged([
          for (final m in _asMapList(j, 'novel chapter')) _toNovelChapter(m),
        ]),
      );

  @override
  Future<NovelDocument> getNovelDocument(
    String novelId,
    String chapterId,
  ) =>
      _run(
        'prepareChapter',
        [novelId, chapterId],
        'handleChapter',
        (json) {
          final map = _asMap(json, 'novel chapter');
          // 源脚本是用户可安装的,畸形返回值要走已有的错误处理，
          // 而不是以裸 TypeError 崩掉。
          final content = map['content'];
          if (content is! String) {
            throw const FormatException('novel chapter content must be a string');
          }
          return NovelDocument(
            format: map['format'] == 'text'
                ? NovelDocumentFormat.text
                : NovelDocumentFormat.html,
            content: content,
            baseUrl: map['baseUrl'] as String?,
            resources:
                (map['resources'] as Map?)?.cast<String, String>() ?? const {},
          );
        },
      );

  @override
  Future<Manga> getMangaDetail(String mangaId) => _run(
        'prepareMangaInfo',
        [mangaId],
        'handleMangaInfo',
        (j) => _toManga(_asMap(j, 'manga')),
      );

  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) async {
    // `handleChapterList` 可以只返回数组(绝大多数源),也可以返回
    // `{chapters, hasNext}` 表态「目录还有下一页」—— 后者才让 `page` 参数真正
    // 可达,长篇不再被第一页截断。
    final collected = await _runCollection(
      'prepareChapterList',
      [mangaId, page ?? 1],
      'handleChapterList',
      itemsKey: 'chapters',
    );
    final seen = <String>{};
    final chapters = <Chapter>[];
    for (final value in collected.items) {
      final chapter = _toChapter(_asMap(value, 'chapter'));
      if (seen.add(chapter.id)) chapters.add(chapter);
    }
    return Paged(chapters, hasNext: collected.hasNext ?? false);
  }

  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) async {
    final collected = await _runCollection(
      'prepareChapter',
      [mangaId, chapterId],
      'handleChapter',
    );
    final pagesByIndex = <int, PageImage>{};
    for (final value in collected.items) {
      final map = _asMap(value, 'page');
      final page = PageImage(
        index: ScriptValues.requireInt(map, 'index'),
        url: ScriptValues.requireString(map, 'url'),
        // 每图可带 Referer/UA(防盗链);与 VideoTrack 一致,源脚本可选返回。
        headers: ScriptValues.headers(map, 'headers'),
      );
      pagesByIndex.putIfAbsent(page.index, () => page);
    }
    final pages = pagesByIndex.values.toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    return pages;
  }

  @override
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) => _run(
        'prepareVideo',
        [animeId, episodeId],
        'handleVideo',
        (j) => [
          for (final m in _asMapList(j, 'video track'))
            () {
              final url = ScriptValues.requireString(m, 'url');
              return VideoTrack(
                url: url,
                quality: ScriptValues.optionalString(m, 'quality') ?? '',
                headers: ScriptValues.headers(m, 'headers'),
                hls: (m['hls'] as bool?) ?? url.contains('.m3u8'),
                subtitles: decodeSubtitles(m['subtitles']),
              );
            }(),
        ],
      );

  /// `subtitles: [{url, label?, language?}]` —— 源可不给,给了也只认有 url 的。
  @visibleForTesting
  static List<SubtitleAsset> decodeSubtitles(Object? raw) {
    if (raw is! List) return const [];
    final assets = <SubtitleAsset>[];
    for (final entry in raw.whereType<Map>()) {
      final s = entry.cast<String, dynamic>();
      final url = ScriptValues.optionalString(s, 'url');
      if (url == null || url.isEmpty) continue;
      assets.add(SubtitleAsset(
        url: url,
        label: ScriptValues.optionalString(s, 'label') ?? '',
        language: ScriptValues.optionalString(s, 'language'),
      ));
    }
    return assets;
  }

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

  /// 脚本返回的一条记录必须是对象;不是就抛带上下文的 [FormatException]。
  static Map<String, dynamic> _asMap(Object? value, String what) {
    if (value is! Map) {
      throw FormatException(
          '源返回的 $what 不是对象(实际:${ScriptValues._desc(value)})');
    }
    return value.cast<String, dynamic>();
  }

  static List<Map<String, dynamic>> _asMapList(Object? value, String what) {
    if (value is! List) {
      throw FormatException(
          '源返回的 $what 不是数组(实际:${ScriptValues._desc(value)})');
    }
    return [for (final e in value) _asMap(e, what)];
  }

  List<Manga> _mangaList(Object? j) =>
      [for (final m in _asMapList(j, 'manga')) _toManga(m)];

  List<Novel> _novelList(Object? j) =>
      [for (final m in _asMapList(j, 'novel')) _toNovel(m)];

  Manga _toManga(Map<String, dynamic> m) => Manga(
        id: ScriptValues.requireString(m, 'id'),
        title: ScriptValues.optionalString(m, 'title') ?? '',
        url: ScriptValues.optionalString(m, 'url'),
        cover: ScriptValues.optionalString(m, 'cover'),
        authors: ScriptValues.stringList(m, 'authors'),
        genres: ScriptValues.stringList(m, 'genres'),
        description: ScriptValues.optionalString(m, 'description'),
        status: _parseStatus(ScriptValues.optionalString(m, 'status')),
        updatedAt: ScriptValues.optionalInt(m, 'updatedAt'),
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

  Novel _toNovel(Map<String, dynamic> m) => Novel(
        id: ScriptValues.requireString(m, 'id'),
        title: ScriptValues.optionalString(m, 'title') ?? '',
        url: ScriptValues.optionalString(m, 'url'),
        cover: ScriptValues.optionalString(m, 'cover'),
        authors: ScriptValues.stringList(m, 'authors'),
        genres: ScriptValues.stringList(m, 'genres'),
        description: ScriptValues.optionalString(m, 'description'),
        status: _parseNovelStatus(ScriptValues.optionalString(m, 'status')),
        updatedAt: ScriptValues.optionalInt(m, 'updatedAt'),
      );

  NovelStatus _parseNovelStatus(String? s) {
    switch (s) {
      case 'ongoing':
        return NovelStatus.ongoing;
      case 'completed':
        return NovelStatus.completed;
      case 'hiatus':
        return NovelStatus.hiatus;
      case 'cancelled':
        return NovelStatus.cancelled;
      default:
        return NovelStatus.unknown;
    }
  }

  NovelChapter _toNovelChapter(Map<String, dynamic> m) => NovelChapter(
        id: ScriptValues.requireString(m, 'id'),
        title: ScriptValues.optionalString(m, 'title') ??
            ScriptValues.optionalString(m, 'name') ??
            '',
        number: ScriptValues.optionalDouble(m, 'number'),
        publishedAt: ScriptValues.optionalInt(m, 'publishedAt'),
        volumeId: ScriptValues.optionalString(m, 'volumeId'),
        volumeTitle: ScriptValues.optionalString(m, 'volumeTitle'),
        epubAnchor: ScriptValues.optionalString(m, 'epubAnchor'),
      );

  Chapter _toChapter(Map<String, dynamic> m) => Chapter(
        id: ScriptValues.requireString(m, 'id'),
        name: ScriptValues.optionalString(m, 'name') ?? '',
        url: ScriptValues.optionalString(m, 'url'),
        number: ScriptValues.optionalDouble(m, 'number'),
        publishedAt: ScriptValues.optionalInt(m, 'publishedAt'),
      );
}
