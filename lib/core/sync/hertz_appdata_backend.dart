import 'dart:convert';

import 'package:hertz_sdk/hertz_sdk.dart';

import '../log/app_log.dart';
import '../net/iam_auth.dart';
import 'sync_backend.dart';
import 'sync_messages.dart';

/// 标准数据 SDK 后端：把同步 blob 存到 hertz **appdata** 服务
/// （`/api/v1/data/{app}/{key}`，多 doc_key + 内容哈希版本）。
///
/// 和 `HertzAccountBackend` 的区别只在协议：
///   - 旧的走 `dreamreader-sync` 的 `/api/v1/sync`（一条整包 + ETag）
///   - 这个走 NetSDKstudy 的 appdata（标准 SDK 的那套）
///
/// 第一版**仍然整包存一个 key**（[blobKey]）：先把传输换掉、行为不变。
/// 等服务端部署好、链路跑通，再把 blob 拆成 manga:favorites / settings:*
/// —— 拆了才吃得 per-key 版本、按需拉取和公开摘要。
class HertzAppDataBackend implements SyncBackend {
  HertzAppDataBackend({
    required String baseUrl,
    required this.auth,
    this.appId = defaultAppId,
    HertzTransport? transport,
    Future<String?> Function()? tokenSource,
  })  : baseUrl = _norm(baseUrl),
        _transport = transport,
        _tokenSource = tokenSource;

  static const defaultAppId = 'dream_manga_reader';
  static const blobKey = 'save:all';

  final String baseUrl;
  final IamAuth auth;
  final String appId;
  final HertzTransport? _transport;

  /// 取 token 的来源。默认走 [IamAuth]；测试可以注入一个假的。
  final Future<String?> Function()? _tokenSource;

  late final HertzClient _client = HertzClient(HertzClientOptions(
    baseUrl: baseUrl,
    appId: appId,
    tokenProvider: () async {
      // 实例字段不会像局部变量那样做 null 提升，先取到局部再判
      final src = _tokenSource;
      if (src != null) return await src();
      return await auth.validAccessToken();
    },
    transport: _transport,
    onRetry: (info) => AppLog.i.warn(LogCat.sync, info.toString()),
  ));

  /// 上一次读到的版本，`push` 时当 If-Match 用。
  ///
  /// 一个后端实例只在一次同步里复用（pull 记版本 → push 带版本），
  /// 和 `HertzAccountBackend` 的约定一致。
  String _version = '';

  @override
  Future<SyncTestResult> test() async {
    if (!auth.isLoggedIn) {
      return SyncTestResult.failure(SyncMessage.serviceOnlineNotLoggedIn);
    }
    try {
      // HEAD：既能探活、又能验证鉴权，还不传数据
      await _client.loadMeta(blobKey);
      return SyncTestResult.success(SyncMessage.testAccountReady);
    } on HertzException catch (e) {
      if (e.isNotFound) {
        // 服务在线、鉴权通过，只是这个账号还没有数据
        return SyncTestResult.success(SyncMessage.testAccountReady);
      }
      if (e.isUnauthorized) {
        return SyncTestResult.failure(SyncMessage.sessionExpired);
      }
      if (e.isNetwork) {
        return SyncTestResult.failure(SyncMessage.unreachable, detail: e.message);
      }
      return SyncTestResult.failure(
        SyncMessage.unexpectedStatus,
        httpStatus: e.status,
      );
    }
  }

  @override
  Future<Map<String, dynamic>?> pull() async {
    try {
      // 刻意**不用** `loadIfChanged`：上层把 `null` 解释成「云端没有数据」，
      // 304 若也返回 null，双向合并会退化成「只用本地」，接着就可能把云端盖掉
      // —— 那正是「收藏丢了」那类事故的形状。
      // 要省流量，得先让上层认识「没变化」这个第三种状态，那是下一步的事。
      final doc = await _client.load(blobKey);
      _version = doc.version;
      return _asBlob(doc.data);
    } on HertzException catch (e) {
      if (e.isNotFound) {
        _version = '';
        return null; // 首次同步
      }
      if (e.isUnauthorized) {
        throw SyncException.of(SyncMessage.sessionExpired);
      }
      throw SyncException.of(SyncMessage.pullFailed, httpStatus: e.status);
    }
  }

  @override
  Future<void> push(Map<String, dynamic> blob) async {
    try {
      final meta = await _client.save(
        blobKey,
        utf8.encode(jsonEncode(blob)),
        SaveOptions(ifMatch: _version, contentType: 'application/json'),
      );
      _version = meta.version;
    } on HertzException catch (e) {
      if (e.isUnauthorized) {
        throw SyncException.of(SyncMessage.sessionExpired);
      }
      if (e.isConflict) {
        // 并发写入：把服务端当前态带回去，让上层重新合并后重试。
        // 注意 SDK 在抛出 409 之前已经做过一次「内容哈希幂等确认」——
        // 走到这里说明确实有别人写过不同的内容。
        throw SyncConflict(await _reloadRemote());
      }
      if (e.isTooLarge) {
        throw SyncException.of(SyncMessage.pushFailed, httpStatus: 413);
      }
      throw SyncException.of(SyncMessage.pushFailed, httpStatus: e.status);
    }
  }

  Future<Map<String, dynamic>?> _reloadRemote() async {
    try {
      final doc = await _client.load(blobKey);
      _version = doc.version;
      return _asBlob(doc.data);
    } on HertzException {
      return null;
    }
  }

  static Map<String, dynamic>? _asBlob(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    return null;
  }

  static String _norm(String u) {
    var s = u.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
