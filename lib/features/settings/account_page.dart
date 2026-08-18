import 'package:flutter/material.dart';

import '../../app/auth_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/bili/bili_auth.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/sync/sync_controller.dart';
import '../../ui/ui.dart';
import 'auth_page.dart';
import 'source_account.dart';
import 'sync_page.dart';

/// 统一账号页:App 自己的账号 + 所有源的账号,都在这一页。
///
/// 以前是散的 —— B 站扫码在番剧页、梦漫账号在云同步页、源账号只能从「源管理」里
/// 一行一行点进去。现在这里是**唯一一处能看全登录态的地方**;别处保留的入口
/// (源管理行内、番剧页顶部)都只是快捷方式,走的是同一套实现,见 [sourceAccounts]。
///
/// 云同步的**同步配置**(后端 / 类别 / 自定义服务器)仍在云同步页,这里只管登录。
class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final SyncController _sync = SyncController.instance;
  Future<void> _iamLogin() async {
    // 登录 / 注册 / 找回密码全在这一页里完成。以前这里要先判断预设、必要时把
    // 配置塞回去、再跳浏览器,登完还得 `Future.delayed(1800ms)` 等 userinfo 异步
    // 落地才敢刷新昵称 —— 现在地址是常量、昵称随登录响应一起回来,都不需要了。
    if (await openAuthPage(context) && mounted) setState(() {});
  }

  Future<void> _openSync() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SyncPage()));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    final auth = AuthScope.of(context);
    final accounts = sourceAccounts();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(l10n.sync_account,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      ),
      body: AppScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _iamCard(p, l10n),
          const SizedBox(height: 24),
          _sectionHeader(p, l10n.acct_sourceSection, l10n.acct_sourceSectionHint),
          const SizedBox(height: 10),
          if (accounts.isEmpty)
            _empty(p, l10n.acct_noSourceLogins)
          else
            // B 站的登录态在 BiliAuth 里,脚本源的在 AuthStore 里 —— 两边都得听,
            // 否则扫码登录完这一页不会自己变。
            ListenableBuilder(
              listenable: Listenable.merge([BiliAuth.instance, auth]),
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final account in accounts) ...[
                    _sourceCard(p, l10n, account, auth),
                    if (account != accounts.last) const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  // —— 梦漫账号(云同步 / IAM)——
  Widget _iamCard(AppPalette p, AppLocalizations l10n) {
    final auth = _sync.auth;
    final on = auth.isLoggedIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          p,
          icon: Icons.cloud_rounded,
          brand: p.accent,
          title: l10n.acct_appAccount,
          subtitle: on
              ? (auth.username?.isNotEmpty == true
                  ? auth.username!
                  : l10n.acct_loggedIn)
              : l10n.acct_appAccountHint,
          loggedIn: on,
          onLogin: _iamLogin,
          onLogout: () async {
            await _sync.auth.logout();
            if (mounted) setState(() {});
          },
          loginLabel: l10n.sync_login,
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _openSync,
            icon: const Icon(Icons.tune_rounded, size: 16),
            label: Text(l10n.acct_syncSettings),
            style: TextButton.styleFrom(
                foregroundColor: p.textMuted,
                textStyle: const TextStyle(fontSize: 12.5)),
          ),
        ),
      ],
    );
  }

  // —— 源账号:B 站扫码与脚本源账密共用一张卡,差别只在点下去弹什么 ——
  Widget _sourceCard(
    AppPalette p,
    AppLocalizations l10n,
    SourceAccount account,
    AuthStore auth,
  ) {
    final on = isSourceAccountLoggedIn(account, auth);
    final who = sourceAccountUser(account, auth);
    final qr = account.kind == SourceLoginKind.qr;
    return _card(
      p,
      icon: qr ? Icons.live_tv_rounded : Icons.source_rounded,
      brand: qr ? const Color(0xFFFF6699) : p.accent,
      title: account.name,
      subtitle: on
          ? (who ?? l10n.acct_loggedIn)
          : account.isShared
              ? l10n.acct_sharedSources(account.sources.length)
              : (qr ? l10n.anime_biliLoginHint : l10n.acct_needsAccount),
      loggedIn: on,
      onLogin: () async {
        await openSourceLogin(context, account);
        if (mounted) setState(() {});
      },
      onLogout: () async {
        await logoutSourceAccount(account, auth);
        if (mounted) setState(() {});
      },
      loginLabel: qr ? l10n.anime_biliScanLogin : l10n.sync_login,
    );
  }

  Widget _sectionHeader(AppPalette p, String title, String hint) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 3),
          Text(hint,
              style:
                  TextStyle(color: p.textMuted, fontSize: 11.5, height: 1.4)),
        ],
      );

  Widget _empty(AppPalette p, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(context.radius),
          border: Border.all(color: p.line),
        ),
        alignment: Alignment.center,
        child: Text(text,
            style: TextStyle(color: p.textMuted, fontSize: 12.5)),
      );

  Widget _card(
    AppPalette p, {
    required IconData icon,
    required Color brand,
    required String title,
    required String subtitle,
    required bool loggedIn,
    required VoidCallback onLogin,
    required VoidCallback onLogout,
    required String loginLabel,
    bool busy = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(context.radius),
        border: Border.all(color: p.line),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: brand.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: brand, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: p.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w800)),
                    ),
                    if (loggedIn) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.verified_rounded, size: 15, color: brand),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.textMuted, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
          else if (loggedIn)
            TextButton(
                onPressed: onLogout, child: Text(context.l10n.anime_signOut))
          else
            FilledButton(
              onPressed: onLogin,
              style: FilledButton.styleFrom(
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: Text(loginLabel),
            ),
        ],
      ),
    );
  }
}
