import 'package:flutter/widgets.dart';

import '../../app/auth_store.dart';
import '../../core/bili/bili_auth.dart';
import '../../core/source/source_registry.dart';
import '../anime/bili_login_page.dart';
import '../common/transitions.dart';
import 'source_login_sheet.dart';

/// 源的登录方式。引擎只认两种,因为源本身只有两种:
/// 脚本源在 `prepareLogin/handleLogin` 里用账密换 token;B 站是内置源,走扫码。
enum SourceLoginKind { password, qr }

/// 一份**源登录凭据**。
///
/// 注意这不等于「一个源」:多个源可以通过 `authKey` 共用同一份登录(晓桀的漫画 /
/// 小说 / 番剧三源就共用一个),那在账号列表里应当是**一行**。按源来列会变成三张
/// 卡、登一个全亮,看着像坏了。
class SourceAccount {
  const SourceAccount({required this.primary, required this.sources});

  /// 代表源:拿它的名字和登录协议。
  final SourceMeta primary;

  /// 共用这份凭据的全部源(含 [primary])。
  final List<SourceMeta> sources;

  String get id => primary.credentialKey;

  String get name => primary.name;

  bool get isShared => sources.length > 1;

  SourceLoginKind get kind =>
      primary.id == kBiliSourceId ? SourceLoginKind.qr : SourceLoginKind.password;
}

/// 所有需要登录的源,按凭据合并。顺序跟着 [registeredSources],所以内置的 B 站
/// 在最前 —— 它是唯一一个「装上就有」的账号。
List<SourceAccount> sourceAccounts() {
  final grouped = <String, List<SourceMeta>>{};
  final order = <String>[];
  for (final meta in registeredSources) {
    if (!meta.needsLogin) continue;
    final key = meta.credentialKey;
    if (grouped.putIfAbsent(key, () => []).isEmpty) order.add(key);
    grouped[key]!.add(meta);
  }
  return [
    for (final key in order)
      SourceAccount(primary: grouped[key]!.first, sources: grouped[key]!),
  ];
}

/// 某个源属于哪份凭据。源管理页按源列行,要反查回凭据才能拿对登录态。
SourceAccount sourceAccountFor(SourceMeta meta) {
  final shared = registeredSources
      .where((other) => other.credentialKey == meta.credentialKey)
      .toList();
  return SourceAccount(
    primary: shared.isEmpty ? meta : shared.first,
    sources: shared.isEmpty ? [meta] : shared,
  );
}

/// 这份凭据登没登。两种登录方式各有各的存放处 —— 扫码登录的状态在 [BiliAuth],
/// 账密登录的在 [AuthStore]。问错地方就会出现「明明登着却显示未登录」。
bool isSourceAccountLoggedIn(SourceAccount account, AuthStore auth) =>
    switch (account.kind) {
      SourceLoginKind.qr => BiliAuth.instance.isLoggedIn,
      SourceLoginKind.password => auth.isLoggedIn(account.primary.id),
    };

/// 已登录时显示的名字;拿不到就返回 null,由调用方兜一句「已登录」。
String? sourceAccountUser(SourceAccount account, AuthStore auth) {
  final name = switch (account.kind) {
    SourceLoginKind.qr => BiliAuth.instance.uname,
    SourceLoginKind.password => auth.nicknameOf(account.primary.id) ??
        auth.usernameOf(account.primary.id),
  };
  return (name?.isEmpty ?? true) ? null : name;
}

/// 打开这份凭据对应的登录界面。**所有入口都走这里** —— 账号页、源管理页行内按钮,
/// 谁都不许自己决定弹哪个界面,否则又会出现给扫码源弹账密表单那种事。
Future<void> openSourceLogin(BuildContext context, SourceAccount account) =>
    switch (account.kind) {
      SourceLoginKind.qr =>
        pushPage<bool>(context, const BiliLoginPage()),
      SourceLoginKind.password =>
        showSourceLoginSheet(context, account.primary),
    };

Future<void> logoutSourceAccount(SourceAccount account, AuthStore auth) =>
    switch (account.kind) {
      SourceLoginKind.qr => BiliAuth.instance.logout(),
      SourceLoginKind.password => auth.logout(account.primary.id),
    };
