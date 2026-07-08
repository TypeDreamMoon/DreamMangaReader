import 'package:flutter/material.dart';

import '../../app/auth_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';

/// 通用源账号登录页。某些源的内容(详情/章节/图片)需要登录后才能读;登录后 App 用
/// 你的账号 Token 直连该源 API。登录**协议**在源脚本里,本页只做通用 UI。**密码不落盘**。
class SourceLoginPage extends StatefulWidget {
  const SourceLoginPage({super.key, required this.meta});

  final SourceMeta meta;

  @override
  State<SourceLoginPage> createState() => _SourceLoginPageState();
}

class _SourceLoginPageState extends State<SourceLoginPage> {
  final _userCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  String get _sourceName => widget.meta.name;

  @override
  void dispose() {
    _userCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _login(AuthStore auth) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await auth.login(widget.meta, _userCtrl.text, _pwCtrl.text);
      if (mounted) {
        _pwCtrl.clear();
        showAppNotify(context, '已登录,$_sourceName 现在走账号 API',
            kind: AppNotifyKind.success);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final auth = AuthScope.of(context);
    final id = widget.meta.id;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text('$_sourceName 账号',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Text(
              '$_sourceName 的内容(详情 / 章节 / 图片)需要登录后才能读。登录后本 App 用你的账号 '
              'Token 直连该源 API,比未登录路径更快更稳、也不易被限流。\n\n'
              '• 用你自己在该源的账号。没有就去它的官方 App/网站注册。\n'
              '• 登录可能需要能访问该源(通常要开代理/翻墙)。\n'
              '• 只在本机保存登录 Token,不保存密码。',
              style: TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.5),
            ),
          ),
          const SizedBox(height: 20),
          if (auth.isLoggedIn(id)) _loggedIn(p, auth) else _loginForm(p, auth),
        ],
      ),
    );
  }

  Widget _loggedIn(AppPalette p, AuthStore auth) {
    final id = widget.meta.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_rounded, color: p.accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '已登录:${auth.nicknameOf(id) ?? auth.usernameOf(id) ?? ''}',
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text('$_sourceName 现在走账号 API 取内容。',
            style: TextStyle(color: p.textMuted, fontSize: 12)),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  await auth.logout(id);
                  if (mounted) {
                    showAppNotify(context, '已退出登录',
                        kind: AppNotifyKind.success);
                  }
                },
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: const Text('退出登录'),
        ),
      ],
    );
  }

  Widget _loginForm(AppPalette p, AuthStore auth) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTextField(
          controller: _userCtrl,
          enabled: !_busy,
          label: '账号(用户名 / 邮箱)',
          autofillHints: const [AutofillHints.username],
        ),
        const SizedBox(height: 14),
        AppTextField(
          controller: _pwCtrl,
          enabled: !_busy,
          obscure: _obscure,
          label: '密码',
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _busy ? null : _login(auth),
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                size: 20),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: TextStyle(color: p.statusFail, fontSize: 12.5)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : () => _login(auth),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
      ],
    );
  }
}
