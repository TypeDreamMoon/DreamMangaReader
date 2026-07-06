/// 源引擎可读的**按源登录 token 句柄**(放 core,避免 core→app 反向依赖)。
///
/// App 层的 AuthStore 在 load/login/logout 时写各源的 token;[ScriptSource] 每次跑某源
/// 脚本前把该源的 token 注入 JS 全局 `__sourceToken`,需要登录的源据此给内容请求带
/// `Authorization`。源脚本是纯函数沙箱、拿不到 App 状态,这是把「登录态」喂进去的唯一通道。
class SourceAuth {
  SourceAuth._();

  static final Map<String, String> _tokens = {};

  /// 取某源当前登录 token;未登录为 null。
  static String? tokenFor(String sourceId) => _tokens[sourceId];

  /// 设置/清除某源 token(空 = 清除)。
  static void set(String sourceId, String? token) {
    if (token == null || token.isEmpty) {
      _tokens.remove(sourceId);
    } else {
      _tokens[sourceId] = token;
    }
  }
}
