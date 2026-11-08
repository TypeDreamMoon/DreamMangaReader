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
///   - 这个走 NetSDKstudy 的 appdata（标准 SDK 的那套），**单独一个域名**
///
/// 第一版**仍然整包存一个 key**（[blobKey]）：先把传输换掉、行为不变。
/// 等服务端部署好、链路跑通，再把 blob 拆成 manga:favorites / settings:*
/// —— 拆了才吃得 per-key 版本、按需拉取和公开摘要。
///
/// 并发写入的约定（和服务端契约一一对应）：
///   - 手上有版本 → `If-Match: <version>`：别人写过回 409，记录没了回 412
///   - 手上没版本（首次同步）→ `If-None-Match: *` **只创建**：别人先建了回 409
///   - 409 / 412 都走「重新拉远端 → 上层重合并 → 再推」，绝不无条件覆盖
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

  /// 上一次读到的版本，`push` 时当 If-Match 用；空 = 云端还没有这条（首推只创建）。
  ///
  /// 一个后端实例只在一次同步里复用（pull 记版本 → push 带版本），
  /// 和 `HertzAccountBackend` 的约定一致。
  String _version = '';

  /// 是不是 **appdata 自己**说的「没有这条记录」。
  ///
  /// 只看 404 不够：地址配错（指到了别的服务、反代没配好）时回的也是 404，
  /// 只是 body 是 `404 page not found` 之类、没有业务码。把那种 404 当成「云端
  /// 没数据」，接下来的推送就会在一个错的地方「首次上传」，用户以为同步好了，
  /// 换台设备一拉——什么都没有。
  static bool _isRecordMissing(HertzException e) =>
      e.isNotFound && e.code == HertzErrorCode.notFound;

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
      if (_isRecordMissing(e)) {
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
        detail: _detail(e),
      );
    }
  }

  @override
  Future<Map<String, dynamic>?> pull() async {
    final LoadedDoc doc;
    try {
      // 刻意**不用** `loadIfChanged`：上层把 `null` 解释成「云端没有数据」，
      // 304 若也返回 null，双向合并会退化成「只用本地」，接着就可能把云端盖掉
      // —— 那正是「收藏丢了」那类事故的形状。
      // 要省流量，得先让上层认识「没变化」这个第三种状态，那是下一步的事。
      doc = await _client.load(blobKey);
    } on HertzException catch (e) {
      if (_isRecordMissing(e)) {
        _version = '';
        return null; // 首次同步
      }
      if (e.isUnauthorized) {
        throw SyncException.of(SyncMessage.sessionExpired);
      }
      throw SyncException.of(SyncMessage.pullFailed,
          httpStatus: e.status, detail: _detail(e));
    }
    return _accept(doc, SyncMessage.pullFailed);
  }

  @override
  Future<void> push(Map<String, dynamic> blob) async {
    final DocMeta meta;
    try {
      meta = await _client.save(
        blobKey,
        utf8.encode(jsonEncode(blob)),
        _version.isEmpty
            // 首推**只创建**：两台设备同时首次同步时，后到的那台会收到 409，
            // 走下面的重合并，而不是把先到的整份盖掉。
            ? const SaveOptions(createOnly: true, contentType: 'application/json')
            : SaveOptions(ifMatch: _version, contentType: 'application/json'),
      );
    } on HertzException catch (e) {
      if (e.isUnauthorized) {
        throw SyncException.of(SyncMessage.sessionExpired);
      }
      if (e.isConflict || e.isPreconditionFailed) {
        // 409：别的设备写过（或首推时已经有人建好了）；
        // 412：带着版本去写，记录却已经不在了（被删了）。
        // 两种都把服务端当前态带回去，让上层重新合并后重试。
        // 注意 SDK 在抛出 409 之前已经做过一次「内容哈希幂等确认」——
        // 走到这里说明确实有别人写过不同的内容。
        throw SyncConflict(await _reloadRemote());
      }
      if (e.isTooLarge) {
        throw SyncException.of(SyncMessage.pushFailed,
            httpStatus: 413, detail: _detail(e));
      }
      throw SyncException.of(SyncMessage.pushFailed,
          httpStatus: e.status, detail: _detail(e));
    }
    if (meta.version.isEmpty) {
      // 写成功了，但服务端没回版本。不能悄悄留空：空版本下次会被当成「云端没有」
      // 去做只创建，或者（旧逻辑里）干脆无条件覆盖。当失败报出来，下次同步重新拉。
      _version = '';
      throw SyncException.of(SyncMessage.pushFailed,
          detail: 'appdata 写入响应缺少 version');
    }
    _version = meta.version;
  }

  /// 冲突后重新拉一次远端：返回 null 只表示「记录确实不存在」（下一次推送会只创建）。
  ///
  /// 其它失败**不能**折成 null：上层会把 `SyncConflict(null)` 理解成「服务端已被
  /// 清空」，拿本地整份去覆盖——一次网络抖动就够让别的设备写的内容丢掉。
  Future<Map<String, dynamic>?> _reloadRemote() async {
    final LoadedDoc doc;
    try {
      doc = await _client.load(blobKey);
    } on HertzException catch (e) {
      if (_isRecordMissing(e)) {
        _version = '';
        return null;
      }
      if (e.isUnauthorized) {
        throw SyncException.of(SyncMessage.sessionExpired);
      }
      throw SyncException.of(SyncMessage.pushFailed,
          httpStatus: e.status, detail: _detail(e));
    }
    return _accept(doc, SyncMessage.pushFailed);
  }

  /// 读到一条已存在的记录：记版本、解 blob。任何一项不对都当失败（[failure]），
  /// 不当「没有数据」。
  Map<String, dynamic> _accept(LoadedDoc doc, SyncMessage failure) {
    if (doc.version.isEmpty) {
      throw SyncException.of(failure, detail: 'appdata 响应缺少 X-Version');
    }
    final blob = _asBlob(doc.data, failure);
    _version = doc.version;
    return blob;
  }

  /// 记录**存在**时它的内容必须是一个 JSON 对象。
  ///
  /// 空 body、解不开、或解出来不是对象，都说明这条数据坏了（或不是本 App 写的）。
  /// 以前这里返回 null，而 null 在上层的意思是「云端没有数据」——于是一份坏掉的
  /// 云端存档会被本地整份覆盖，坏的那份连排查的机会都没有。
  static Map<String, dynamic> _asBlob(List<int> bytes, SyncMessage failure) {
    if (bytes.isEmpty) {
      throw SyncException.of(failure, detail: 'appdata 记录内容为空');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw SyncException.of(failure, detail: '云端数据不是合法 JSON:${e.message}');
    }
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw SyncException.of(failure,
        detail: '云端数据不是 JSON 对象(${decoded.runtimeType})');
  }

  /// 给日志 / 设置页的排查信息：HTTP 状态 + 业务码 + 服务端原话。
  /// 原话可能是一整页 HTML（地址配错时），截一段就够认出是谁回的。
  static String _detail(HertzException e) {
    final msg = e.message.trim();
    final short = msg.length > 160 ? '${msg.substring(0, 160)}…' : msg;
    return 'HTTP ${e.status} · code ${e.code} · $short';
  }

  static String _norm(String u) {
    var s = u.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
