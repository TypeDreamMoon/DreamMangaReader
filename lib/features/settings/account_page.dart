import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/bili/bili_auth.dart';
import '../../core/sync/sync_controller.dart';
import '../../ui/ui.dart';
import '../anime/bili_login_page.dart';
import '../common/transitions.dart';
import 'sync_page.dart';

/// 统一账号页:把「哔哩哔哩」扫码登录与「梦漫账号(云同步 / Hertz IAM)」登录集中到一处,
/// 不再分散在番剧页 / 云同步页。云同步的**同步配置**(后端/类别/自动)仍在云同步页,这里只管登录。
class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final SyncController _sync = SyncController.instance;
  bool _iamBusy = false;

  Future<void> _biliLogin() async {
    await Navigator.of(context).push<bool>(appRoute(const BiliLoginPage()));
    if (mounted) setState(() {});
  }

  Future<void> _biliLogout() async {
    await BiliAuth.instance.logout();
    if (mounted) setState(() {});
  }

  Future<void> _iamLogin() async {
    // 自定义自建 IAM(hertzPreset=custom + 已填 issuer)多用密码登录、无浏览器回调,
    // 本页没有账密输入框 → 转交云同步页(它有预设感知的密码/浏览器登录 UI)。
    if (_sync.hertzPreset == 'custom' && _sync.hertzIssuer.trim().isNotEmpty) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const SyncPage()));
      if (mounted) setState(() {});
      return;
    }
    setState(() => _iamBusy = true);
    try {
      // 新用户没配过账号服务地址时,默认套官方「梦漫账号」服务(浏览器 OAuth)。
      if (_sync.hertzIssuer.trim().isEmpty) {
        await _sync.saveHertzConfig(
          syncUrl: SyncController.hzPresetSyncUrl,
          issuer: SyncController.hzPresetIssuer,
          clientId: SyncController.hzPresetClientId,
        );
      }
      await _sync.auth.loginBrowser();
      if (!mounted) return;
      showAppNotify(context, '登录成功', kind: AppNotifyKind.success);
      // 昵称是登录后异步拉取的(IamAuth 非 ChangeNotifier),稍后再刷让卡片显示账号名。
      Future.delayed(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() {});
      });
    } catch (e) {
      if (!mounted) return;
      showAppNotify(context, '登录失败:$e', kind: AppNotifyKind.error);
    } finally {
      if (mounted) setState(() => _iamBusy = false);
    }
  }

  Future<void> _iamLogout() async {
    await _sync.auth.logout();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('账号',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      ),
      body: AppScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          ListenableBuilder(
            listenable: BiliAuth.instance,
            builder: (_, __) => _biliCard(p),
          ),
          const SizedBox(height: 14),
          _iamCard(p),
        ],
      ),
    );
  }

  // —— 哔哩哔哩 ——
  Widget _biliCard(AppPalette p) {
    final auth = BiliAuth.instance;
    final on = auth.isLoggedIn;
    return _card(
      p,
      icon: Icons.live_tv_rounded,
      brand: const Color(0xFFFF6699),
      title: '哔哩哔哩',
      subtitle: on
          ? (auth.uname?.isNotEmpty == true ? auth.uname! : '已登录')
          : '登录后可看追番、解锁大会员清晰度',
      loggedIn: on,
      onLogin: _biliLogin,
      onLogout: _biliLogout,
      loginLabel: '扫码登录',
    );
  }

  // —— 梦漫账号(云同步 / IAM)——
  Widget _iamCard(AppPalette p) {
    final auth = _sync.auth;
    final on = auth.isLoggedIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          p,
          icon: Icons.cloud_rounded,
          brand: p.accent,
          title: '梦漫账号',
          subtitle: on
              ? (auth.username?.isNotEmpty == true ? auth.username! : '已登录')
              : '用于云同步(书架 / 进度 / 历史 多端同步)',
          loggedIn: on,
          busy: _iamBusy,
          onLogin: _iamLogin,
          onLogout: _iamLogout,
          loginLabel: '登录',
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SyncPage())),
            icon: const Icon(Icons.tune_rounded, size: 16),
            label: const Text('云同步设置(后端 / 类别 / 自定义服务器)'),
            style: TextButton.styleFrom(
                foregroundColor: p.textMuted, textStyle: const TextStyle(fontSize: 12.5)),
          ),
        ),
      ],
    );
  }

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
                    Text(title,
                        style: TextStyle(
                            color: p.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800)),
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
            TextButton(onPressed: onLogout, child: const Text('退出'))
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
