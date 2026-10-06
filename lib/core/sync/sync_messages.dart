import 'package:meta/meta.dart';

/// 同步链路要告诉用户的**事情**(不是文案)。
///
/// 核心层不认识 `BuildContext`,也就不该拼中文串——它只说「发生了什么」,
/// 由设置页按当前语言渲染(见 `lib/features/settings/sync_messages.dart`)。
/// 同 `playback_messages.dart` 那套分工,只是方向相反:那边注入文案,
/// 这边回传码。
enum SyncMessage {
  // ---- 进行中 ----
  syncing,
  uploading,
  downloading,

  // ---- 成功 ----
  synced, // 已同步,带 favorites / history 条数
  uploaded, // 已上传,带 count 个类别
  downloaded, // 已下载,带 count 项
  serverEmpty, // 服务器上还没有数据
  testWebDavReady, // 测试连接:WebDAV 目录就绪
  testAccountReady, // 测试连接:账号已登录

  // ---- 失败 ----
  notConfiguredAccount, // 账号同步未就绪(先配地址并登录)
  notConfiguredWebDav, // 还没配 WebDAV 地址
  noCategoriesChosen, // 一项要同步的内容都没选
  noDownloadChosen, // 一项要下载的内容都没选
  alreadySyncing, // 上一次同步还没结束
  uploadConflictRetries, // 反复撞上并发写入,重试用尽
  notLoggedIn, // 还没登录账号
  sessionExpired, // 登录已过期
  serviceOnlineNotLoggedIn, // 服务在线但没登录
  serviceDown, // 同步服务无响应(带 httpStatus)
  authFailed, // 账号或密码不对(带 httpStatus)
  forbidden, // 权限不足(带 httpStatus)
  pullFailed, // 拉取失败(带 httpStatus)
  pushFailed, // 上传失败(带 httpStatus)
  unexpectedStatus, // 其它异常响应(带 httpStatus)
  unreachable, // 连不上(带 detail)
  autoSyncFailed, // 启动自动同步失败(带 detail)
  autoUploadFailed, // 变化后自动上传失败(带 detail)
}

/// 一条同步消息 + 它需要的数字/细节。
@immutable
class SyncNotice {
  const SyncNotice(
    this.message, {
    this.favorites = 0,
    this.history = 0,
    this.count = 0,
    this.httpStatus,
    this.detail,
  });

  final SyncMessage message;

  /// [SyncMessage.synced] 用:合并后的收藏 / 进度条数。
  final int favorites;
  final int history;

  /// [SyncMessage.uploaded] / [SyncMessage.downloaded] 用:类别数。
  final int count;

  /// HTTP 状态码(有的话)。
  final int? httpStatus;

  /// 底层原因,原样透传给 UI 拼进文案。只在实在说不清时才用。
  final String? detail;

  @override
  String toString() => 'SyncNotice(${message.name}'
      '${httpStatus == null ? '' : ' http=$httpStatus'}'
      '${detail == null ? '' : ' detail=$detail'})';
}

/// 同步失败。带的是码不是中文串,UI 自己翻。
class SyncException implements Exception {
  const SyncException(this.notice);

  SyncException.of(
    SyncMessage message, {
    int? httpStatus,
    String? detail,
  }) : notice = SyncNotice(message, httpStatus: httpStatus, detail: detail);

  final SyncNotice notice;

  @override
  String toString() => 'SyncException(${notice.message.name})';
}

/// 「测试连接」的结果。
@immutable
class SyncTestResult {
  const SyncTestResult({required this.ok, required this.notice});

  factory SyncTestResult.success(SyncMessage message) =>
      SyncTestResult(ok: true, notice: SyncNotice(message));

  factory SyncTestResult.failure(
    SyncMessage message, {
    int? httpStatus,
    String? detail,
  }) =>
      SyncTestResult(
        ok: false,
        notice:
            SyncNotice(message, httpStatus: httpStatus, detail: detail),
      );

  final bool ok;
  final SyncNotice notice;
}
