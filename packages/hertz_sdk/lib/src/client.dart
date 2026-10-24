import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'error.dart';
import 'sha256.dart';
import 'transport.dart';
import 'types.dart';

/// 客户端配置。
class HertzClientOptions {
  HertzClientOptions({
    required this.baseUrl,
    required this.appId,
    this.token = '',
    this.tokenProvider,
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 2,
    this.onRetry,
    HertzTransport? transport,
  }) : transport = transport ?? IoTransport();

  /// 服务地址，如 http://127.0.0.1:8083
  final String baseUrl;

  /// 应用标识（IAM 里注册的 client_id 对齐）
  final String appId;

  /// 静态 token
  final String token;

  /// 动态 token（优先于 [token]）。**必须是「取缓存 → 过期就刷新 → 返回」的完整逻辑**。
  ///
  /// SDK 只在 401 时把缓存丢掉再问一次，它不知道什么是 refresh_token。
  final FutureOr<String?> Function()? tokenProvider;

  final Duration timeout;

  /// 最多重试几次，默认 2（即最多请求 3 次）。
  final int maxRetries;

  /// 重试时回调，用来观测。
  final void Function(RetryInfo info)? onRetry;

  final HertzTransport transport;
}

/// 跟数据服务说话的唯一入口。
///
/// 方法名和 C++ / TS 版**完全一致**——三套 SDK 学会一个就够。
class HertzClient {
  HertzClient(this.opts)
      : _base = _trimSlash(opts.baseUrl),
        _rng = Random();

  final HertzClientOptions opts;
  final String _base;
  final Random _rng;

  String _cachedToken = '';
  bool _hasCachedToken = false;
  Future<String>? _tokenFuture;

  // ── 数据 ──────────────────────────────────────────────

  /// 写一份数据。data 是原始字节，服务端不解析。
  ///
  /// 返回的 version 留着做下次写入的 ifMatch。
  Future<DocMeta> save(String key, List<int> data, [SaveOptions? options]) async {
    final o = options ?? const SaveOptions();
    final body = Uint8List.fromList(data);

    final headers = <String, String>{
      'Content-Type': o.contentType,
      'X-Perm-Read': '${o.permRead}',
      'X-Perm-Write': '${o.permWrite}',
      if (o.ifMatch.isNotEmpty) 'If-Match': o.ifMatch,
    };

    HertzResponse res;
    try {
      res = await _request('PUT', _docPath(key), body: body, headers: headers);
    } on HertzException catch (e) {
      // 「写成功了，但响应在网络上丢了」——重试会带着同一个旧 If-Match 再打一次，
      // 服务端此刻版本已变，回 409。调用方看到的会是「冲突」，其实自己刚写成了。
      //
      // 服务端的 version 就是内容哈希，所以读一次、比一下就能分辨。
      if (e.isConflict && o.ifMatch.isNotEmpty && o.ifMatch != '*') {
        try {
          final current = await load(key);
          if (current.version == sha256Hex(body)) {
            return DocMeta(
              key: key,
              bytes: current.bytes,
              contentType: o.contentType,
              version: current.version,
              permRead: o.permRead,
              permWrite: o.permWrite,
              updatedAt: current.updatedAt,
            );
          }
        } on HertzException {
          // 读不回来就按原冲突抛——宁可报冲突，也不要把真实冲突吞成成功
        }
      }
      rethrow;
    }

    final data_obj = _envelopeData(res);
    return DocMeta(
      key: key,
      bytes: body.length,
      contentType: o.contentType,
      version: (data_obj['version'] as String?) ?? '',
      permRead: o.permRead,
      permWrite: o.permWrite,
      updatedAt: (data_obj['updated_at'] as String?) ?? '',
    );
  }

  /// 读自己的一份数据。读不到抛 [HertzException]（isNotFound）。
  Future<LoadedDoc> load(String key) async {
    final res = await _request('GET', _docPath(key));
    return _loadedFrom(key, res);
  }

  /// 只取元信息（HEAD），**不下载内容**。
  ///
  /// 用途是「先比版本，再决定要不要下」：每天检查云端有没有新档时，
  /// 不用为了一个 version 付整包的钱。
  Future<DocMeta> loadMeta(String key) async {
    final res = await _request('HEAD', _docPath(key));
    return _metaFrom(key, res);
  }

  /// 条件 GET：服务端版本和你手上的相同时返回 304，一个字节都不传。
  ///
  /// 304 不算失败，所以返回 [LoadResult] 而不是抛异常。
  Future<LoadResult> loadIfChanged(String key, String knownVersion) async {
    final headers = <String, String>{
      if (knownVersion.isNotEmpty) 'If-None-Match': '"$knownVersion"',
    };
    final res = await _request('GET', _docPath(key), headers: headers);
    if (res.status == 304) return const LoadResult.notModified();
    return LoadResult.fresh(_loadedFrom(key, res));
  }

  /// 删自己的一份数据。不存在时抛 isNotFound。
  Future<void> remove(String key) async {
    await _request('DELETE', _docPath(key), retryable: false);
  }

  /// 列出自己在这个应用下的数据，自动翻页。
  Stream<DocMeta> list([ListOptions options = const ListOptions()]) async* {
    final page = options.pageSize > 0 ? options.pageSize : 50;
    var after = '';
    for (;;) {
      final qs = <String>['limit=$page'];
      if (options.prefix.isNotEmpty) {
        qs.add('prefix=${Uri.encodeComponent(options.prefix)}');
      }
      if (after.isNotEmpty) {
        qs.add('after=${Uri.encodeComponent(after)}');
      }

      final res = await _request('GET', '${_appPath()}?${qs.join('&')}');
      final dataObj = _envelopeData(res);
      final items = (dataObj['items'] as List?) ?? const [];

      for (final it in items) {
        if (it is Map) yield _metaFromJson(it.cast<String, dynamic>());
      }

      final next = (dataObj['next_after'] as String?) ?? '';
      if (next.isEmpty || items.isEmpty) return;
      after = next;
    }
  }

  // ── 摘要（给社区页看） ────────────────────────────────

  /// 上报一份公开摘要：doc_key 默认是 showcase，权限自动设成 Public。
  Future<DocMeta> publishSummary(Object? summary, {String key = 'showcase'}) {
    return save(
      key,
      utf8.encode(jsonEncode(summary)),
      SaveOptions(
        permRead: PermRead.public,
        contentType: 'application/json',
      ),
    );
  }

  /// 读**别人**公开的摘要。这是「库街区能看到游戏数据」那条路。
  ///
  /// 返回原始 JSON 文本（和 C++ 版一致；调用方自己 `jsonDecode`）。
  Future<String> readSummary(String uid, {String key = 'showcase'}) async {
    final path = '/api/v1/public/${Uri.encodeComponent(uid)}'
        '/${Uri.encodeComponent(opts.appId)}/${Uri.encodeComponent(key)}';
    final res = await _request('GET', path);
    return res.bodyText;
  }

  // ── 其它 ──────────────────────────────────────────────

  /// 当前缓存的 token（测试用）
  String get cachedToken => _cachedToken;

  /// 丢掉缓存的 token（下次请求会重新取）。401 之后内部会自己调。
  void invalidateToken() {
    _hasCachedToken = false;
    _cachedToken = '';
  }

  String get appId => opts.appId;

  // ── 内部 ──────────────────────────────────────────────

  static String _trimSlash(String u) {
    var s = u;
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  String _appPath() => '/api/v1/data/${Uri.encodeComponent(opts.appId)}';

  String _docPath(String key) => '${_appPath()}/${Uri.encodeComponent(key)}';

  /// 所有请求的唯一出口。
  ///
  /// 鉴权、超时、重试、错误映射全在这儿，不散到每个方法里。
  Future<HertzResponse> _request(
    String method,
    String path, {
    Uint8List? body,
    Map<String, String>? headers,
    bool retryable = true,
  }) async {
    final attempts = retryable ? opts.maxRetries + 1 : 1;
    var refreshedToken = false;
    var skipBackoff = false;
    var nextDelayMs = 0;
    HertzException? lastErr;

    int willWaitMs(int idx) {
      if (idx + 1 >= attempts) return 0;
      return nextDelayMs > 0 ? nextDelayMs : _backoffMs(idx + 1);
    }

    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0 && !skipBackoff) {
        final delay = nextDelayMs > 0 ? nextDelayMs : _backoffMs(attempt);
        await Future<void>.delayed(Duration(milliseconds: delay));
      }
      nextDelayMs = 0;
      skipBackoff = false;

      final h = <String, String>{
        'Content-Type': 'application/octet-stream',
        ...?headers,
      };
      final token = await _currentToken();
      if (token.isNotEmpty) h['Authorization'] = 'Bearer $token';

      HertzResponse res;
      try {
        res = await opts.transport.send(HertzRequest(
          method: method,
          url: '$_base$path',
          timeoutMs: opts.timeout.inMilliseconds,
          headers: h,
          body: body,
        ));
      } catch (e) {
        lastErr = HertzException(
          HertzErrorKind.network,
          0,
          '$e',
          path: path,
        );
        _notifyRetry(opts.onRetry, attempt, willWaitMs(attempt), lastErr, method, path);
        continue;
      }

      // 304 也当成「正常返回」交给调用方：条件 GET 里它是成功的一种形态。
      // 交给错误映射会被归到 other，然后被当成失败。
      if (res.ok || res.status == 304) return res;

      // token 过期：丢掉缓存重试一次，不退避（这不是网络问题）
      if (res.status == 401 && opts.tokenProvider != null && !refreshedToken) {
        invalidateToken();
        refreshedToken = true;
        skipBackoff = true;
        attempt--; // 续期后的这次不计入重试次数
        continue;
      }

      lastErr = HertzException(
        kindFromStatus(res.status),
        res.status,
        _envelopeMsg(res),
        path: path,
        code: _envelopeCode(res),
      );

      if (!lastErr.retryable) throw lastErr;

      // 429 会告诉我们该等多久——有就照它说的等，别自己猜
      if (res.status == 429) {
        final ra = int.tryParse(res.header('retry-after'));
        if (ra != null && ra > 0) {
          nextDelayMs = min(ra * 1000, 30000);
        }
      }

      _notifyRetry(opts.onRetry, attempt, willWaitMs(attempt), lastErr, method, path);
    }

    throw lastErr ??
        HertzException(HertzErrorKind.other, 0, '没有发起过请求', path: path);
  }

  /// 指数退避 + 抖动。
  ///
  /// 抖动必须**每个进程不同**：没有抖动的话，所有客户端会在同一刻一起重试。
  /// 区间取 [base, 2*base)，和 C++ 版一致。
  int _backoffMs(int attempt) {
    final base = 250 * (1 << (attempt - 1));
    if (base <= 0) return 0;
    return base + _rng.nextInt(base);
  }

  static void _notifyRetry(
    void Function(RetryInfo info)? cb,
    int attempt,
    int delayMs,
    HertzException err,
    String method,
    String path,
  ) {
    if (cb == null) return;
    try {
      cb(RetryInfo(
        attempt: attempt + 1,
        delayMs: delayMs,
        reason: err.message,
        status: err.status,
        method: method,
        path: path,
      ));
    } catch (_) {
      // 观测不该影响业务
    }
  }

  Future<String> _currentToken() async {
    if (_hasCachedToken) return _cachedToken;
    final provider = opts.tokenProvider;
    if (provider == null) return opts.token;

    // single-flight：并发时大家共享同一次取 token，不会把认证服务打挂
    final pending = _tokenFuture;
    if (pending != null) return pending;

    final fut = Future<String>.sync(() async {
      final t = (await provider()) ?? '';
      // 空字符串**不缓存**：登录还没完成时拿到的空值若被钉住，
      // 之后就再也不会去问 provider 了。
      if (t.isNotEmpty) {
        _cachedToken = t;
        _hasCachedToken = true;
      }
      return t;
    }).whenComplete(() {
      _tokenFuture = null;
    });

    _tokenFuture = fut;
    return fut;
  }

  // ── 响应解析 ──────────────────────────────────────────

  static Map<String, dynamic> _envelopeData(HertzResponse res) {
    final text = res.bodyText;
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    if (decoded is Map && decoded['data'] is Map) {
      return (decoded['data'] as Map).cast<String, dynamic>();
    }
    return const {};
  }

  static String _envelopeMsg(HertzResponse res) {
    final text = res.bodyText;
    if (text.isEmpty) return 'HTTP ${res.status}';
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['msg'] is String) {
        return decoded['msg'] as String;
      }
    } catch (_) {
      // 不是 JSON 就用原文
    }
    return text;
  }

  static int _envelopeCode(HertzResponse res) {
    final text = res.bodyText;
    if (text.isEmpty) return 0;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['code'] is int) {
        return decoded['code'] as int;
      }
    } catch (_) {
      // 忽略
    }
    return 0;
  }

  static int _headerInt(HertzResponse res, String name, int def) {
    final v = res.header(name);
    if (v.isEmpty) return def;
    return int.tryParse(v) ?? def;
  }

  static DocMeta _metaFrom(String key, HertzResponse res) => DocMeta(
        key: key,
        bytes: _headerInt(res, 'x-bytes', 0),
        contentType: res.header('content-type'),
        version: res.header('x-version'),
        permRead: _headerInt(res, 'x-perm-read', PermRead.owner),
        permWrite: _headerInt(res, 'x-perm-write', PermWrite.owner),
        updatedAt: res.header('x-updated-at'),
      );

  static LoadedDoc _loadedFrom(String key, HertzResponse res) {
    final data = res.body ?? Uint8List(0);
    return LoadedDoc(
      key: key,
      data: data,
      bytes: data.length,
      contentType: res.header('content-type'),
      version: res.header('x-version'),
      permRead: _headerInt(res, 'x-perm-read', PermRead.owner),
      permWrite: _headerInt(res, 'x-perm-write', PermWrite.owner),
      updatedAt: res.header('x-updated-at'),
    );
  }

  static DocMeta _metaFromJson(Map<String, dynamic> j) => DocMeta(
        key: (j['key'] as String?) ?? '',
        bytes: (j['bytes'] as int?) ?? 0,
        contentType: (j['content_type'] as String?) ?? '',
        version: (j['version'] as String?) ?? '',
        permRead: (j['perm_read'] as int?) ?? PermRead.owner,
        permWrite: (j['perm_write'] as int?) ?? PermWrite.owner,
        updatedAt: (j['updated_at'] as String?) ?? '',
      );
}
