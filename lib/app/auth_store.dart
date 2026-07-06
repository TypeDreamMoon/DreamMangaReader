import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/source/auth_token.dart';
import '../core/source/source_registry.dart';

/// 按源的账号态(登录 token + 昵称)。**只存 token/昵称,不存明文密码**(token 失效就重登)。
///
/// 登录**协议**(登录 host、端点、密码编码、响应解析)全在源脚本的 prepareLogin/handleLogin
/// 里,引擎不感知具体站点——这里只负责调用源登录、持久化结果、并把 token 喂给 [SourceAuth]。
class AuthStore extends ChangeNotifier {
  SharedPreferences? _prefs;

  final Map<String, _Account> _accounts = {};

  bool isLoggedIn(String sourceId) =>
      (_accounts[sourceId]?.token ?? '').isNotEmpty;
  String? nicknameOf(String sourceId) => _accounts[sourceId]?.nickname;
  String? usernameOf(String sourceId) => _accounts[sourceId]?.username;

  /// 启动时读回各源已存的登录态,并同步给源引擎。
  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    for (final meta in registeredSources) {
      final t = prefs.getString('auth.${meta.id}.token');
      if (t == null || t.isEmpty) continue;
      _accounts[meta.id] = _Account(
        token: t,
        username: prefs.getString('auth.${meta.id}.username'),
        nickname: prefs.getString('auth.${meta.id}.nickname'),
      );
      SourceAuth.set(meta.id, t);
    }
    notifyListeners();
  }

  /// 用账号密码登录某源(登录逻辑在源脚本里)。成功后持久化 token 并注入源引擎。
  /// 抛出 [Exception] 表示登录失败(带原因)。
  Future<void> login(SourceMeta meta, String username, String password) async {
    final u = username.trim();
    if (u.isEmpty || password.isEmpty) {
      throw Exception('请输入账号和密码');
    }
    final src = buildSource(meta);
    try {
      final r = await src.login(u, password);
      final nick = r.nickname ?? u;
      _accounts[meta.id] = _Account(token: r.token, username: u, nickname: nick);
      SourceAuth.set(meta.id, r.token);
      await _prefs?.setString('auth.${meta.id}.token', r.token);
      await _prefs?.setString('auth.${meta.id}.username', u);
      await _prefs?.setString('auth.${meta.id}.nickname', nick);
      notifyListeners();
    } finally {
      src.dispose();
    }
  }

  Future<void> logout(String sourceId) async {
    _accounts.remove(sourceId);
    SourceAuth.set(sourceId, null);
    await _prefs?.remove('auth.$sourceId.token');
    await _prefs?.remove('auth.$sourceId.username');
    await _prefs?.remove('auth.$sourceId.nickname');
    notifyListeners();
  }
}

class _Account {
  const _Account({required this.token, this.username, this.nickname});
  final String token;
  final String? username;
  final String? nickname;
}

/// `AuthScope.of(context)` 读账号态;notify 时依赖它的页面自动重建。
class AuthScope extends InheritedNotifier<AuthStore> {
  const AuthScope({
    super.key,
    required AuthStore store,
    required super.child,
  }) : super(notifier: store);

  static AuthStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AuthScope>();
    assert(scope != null, 'AuthScope not found in context');
    return scope!.notifier!;
  }

  static AuthStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AuthScope>();
    assert(scope != null, 'AuthScope not found in context');
    return scope!.notifier!;
  }
}
