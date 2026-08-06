import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/source/auth_token.dart';
import '../core/source/source_registry.dart';
import '../core/storage/secret_store.dart';

/// 按源的账号态(登录 token + 昵称)。**只存 token/昵称,不存明文密码**(token 失效就重登)。
///
/// 登录**协议**(登录 host、端点、密码编码、响应解析)全在源脚本的 prepareLogin/handleLogin
/// 里,引擎不感知具体站点——这里只负责调用源登录、持久化结果、并把 token 喂给 [SourceAuth]。
class AuthStore extends ChangeNotifier {
  AuthStore({SharedPreferences? preferences, SecretStore? secrets})
      : _prefs = preferences,
        _secrets = secrets ?? const FlutterSecretStore();

  SharedPreferences? _prefs;
  final SecretStore _secrets;

  final Map<String, _Account> _accounts = {};

  bool isLoggedIn(String sourceId) =>
      (_accounts[_credentialKeyFor(sourceId)]?.token ?? '').isNotEmpty;
  String? nicknameOf(String sourceId) =>
      _accounts[_credentialKeyFor(sourceId)]?.nickname;
  String? usernameOf(String sourceId) =>
      _accounts[_credentialKeyFor(sourceId)]?.username;

  /// 启动时读回各源已存的登录态,并同步给源引擎。
  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _accounts.clear();
    final groups = <String, List<SourceMeta>>{};
    for (final meta in registeredSources) {
      SourceAuth.set(meta.id, null);
      groups.putIfAbsent(meta.credentialKey, () => []).add(meta);
    }
    for (final entry in groups.entries) {
      final metas = entry.value;
      final t = await readMigratingSecret(
        secrets: _secrets,
        preferences: prefs,
        secureKey: 'source.auth.${entry.key}',
        legacyKeys: metas.map((meta) => 'auth.${meta.id}.token'),
      );
      if (t == null || t.isEmpty) continue;
      String? firstValue(String suffix) {
        final shared = prefs.getString('auth.${entry.key}.$suffix');
        if (shared != null) return shared;
        for (final meta in metas) {
          final value = prefs.getString('auth.${meta.id}.$suffix');
          if (value != null) return value;
        }
        return null;
      }

      _accounts[entry.key] = _Account(
        token: t,
        username: firstValue('username'),
        nickname: firstValue('nickname'),
      );
      for (final meta in metas) {
        SourceAuth.set(meta.id, t);
      }
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
      final key = meta.credentialKey;
      await writeVerifiedSecret(
        secrets: _secrets,
        key: 'source.auth.$key',
        value: r.token,
      );
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      for (final source in _sourcesForCredential(key, fallback: meta)) {
        await prefs.remove('auth.${source.id}.token');
      }
      _accounts[key] = _Account(token: r.token, username: u, nickname: nick);
      _injectCredential(key, r.token, fallback: meta);
      await prefs.setString('auth.$key.username', u);
      await prefs.setString('auth.$key.nickname', nick);
      notifyListeners();
    } finally {
      src.dispose();
    }
  }

  Future<void> logout(String sourceId) async {
    final key = _credentialKeyFor(sourceId);
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _accounts.remove(key);
    await _secrets.delete('source.auth.$key');
    for (final source in _sourcesForCredential(key)) {
      SourceAuth.set(source.id, null);
      await prefs.remove('auth.${source.id}.token');
      await prefs.remove('auth.${source.id}.username');
      await prefs.remove('auth.${source.id}.nickname');
    }
    SourceAuth.set(sourceId, null);
    await prefs.remove('auth.$key.username');
    await prefs.remove('auth.$key.nickname');
    notifyListeners();
  }

  String _credentialKeyFor(String sourceId) {
    for (final meta in registeredSources) {
      if (meta.id == sourceId) return meta.credentialKey;
    }
    return sourceId;
  }

  Iterable<SourceMeta> _sourcesForCredential(
    String key, {
    SourceMeta? fallback,
  }) {
    final matches =
        registeredSources.where((meta) => meta.credentialKey == key);
    if (matches.isNotEmpty) return matches;
    return fallback == null ? const <SourceMeta>[] : [fallback];
  }

  void _injectCredential(String key, String? token, {SourceMeta? fallback}) {
    for (final source in _sourcesForCredential(key, fallback: fallback)) {
      SourceAuth.set(source.id, token);
    }
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
