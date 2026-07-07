/// 同步后端抽象:把「同步 blob」存到某处(WebDAV 文件 / 自建账号服务)。
///
/// 一次同步 = [pull] 拉远端 → 上层与本地无损合并 → [push] 推回。
/// [test] 用于设置页「测试连接」。
abstract class SyncBackend {
  /// 测试连通 / 认证。返回 (是否成功, 人话消息)。
  Future<(bool, String)> test();

  /// 拉远端 blob;还没同步过返回 null。
  Future<Map<String, dynamic>?> pull();

  /// 推 blob 到远端(覆盖 / 带并发校验)。
  ///
  /// 支持乐观并发的后端(账号服务)在检测到远端已被其它设备更新时,应抛
  /// [SyncConflict](携带远端当前 blob),由上层重新合并后重试。
  Future<void> push(Map<String, dynamic> blob);
}

/// 推送时远端已被并发更新(ETag 不匹配)。携带服务端当前 blob 供上层重合并重试。
class SyncConflict implements Exception {
  SyncConflict(this.remote);

  /// 服务端当前 blob(为 null 表示服务端已被清空)。
  final Map<String, dynamic>? remote;

  @override
  String toString() => 'SyncConflict';
}
