import 'package:flutter/material.dart';

import '../../app/auth_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';

/// 源账号登录(账密式)。登录**协议**在源脚本的 `prepareLogin/handleLogin` 里,
/// 这里只做通用 UI。**密码不落盘** —— 只存登录换回来的 token,失效了就重登。
///
/// 账号页和源管理页共用这一个:两个入口,一套实现。别再各写一份。
Future<void> showSourceLoginSheet(BuildContext context, SourceMeta meta) {
  final auth = AuthScope.read(context);
  return showAppSheet<void>(
    context,
    title: context.l10n.srclogin_accountTitle(meta.name),
    titleIcon: Icons.account_circle_rounded,
    showDragHandle: true,
    // 表单里有输入框,键盘弹起来要把弹层顶上去,否则按钮被压在键盘底下。
    resizeForKeyboard: true,
    glass: true,
    topRadius: 22,
    bodyPadding: const EdgeInsets.fromLTRB(18, 4, 18, 20),
    body: (_, __) => _SourceLoginForm(meta: meta, auth: auth),
  );
}

class _SourceLoginForm extends StatefulWidget {
  const _SourceLoginForm({required this.meta, required this.auth});

  final SourceMeta meta;
  final AuthStore auth;

  @override
  State<_SourceLoginForm> createState() => _SourceLoginFormState();
}

class _SourceLoginFormState extends State<_SourceLoginForm> {
  final _userCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  String get _name => widget.meta.name;

  @override
  void dispose() {
    _userCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.login(widget.meta, _userCtrl.text, _pwCtrl.text);
      if (!mounted) return;
      _pwCtrl.clear();
      showAppNotify(context, context.l10n.srclogin_loggedInNow(_name),
          kind: AppNotifyKind.success);
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
    // 登录成功后要就地翻成「已登录」,所以盯着 store 而不是只靠自己的 setState。
    return ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) {
        final p = context.palette;
        return widget.auth.isLoggedIn(widget.meta.id)
            ? _loggedIn(p)
            : _form(p);
      },
    );
  }

  Widget _loggedIn(AppPalette p) {
    final auth = widget.auth;
    final id = widget.meta.id;
    final who = auth.nicknameOf(id) ?? auth.usernameOf(id) ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_rounded, color: p.accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.sync_loggedInAs(who),
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(context.l10n.srclogin_accountApiNow(_name),
            style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5)),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  await auth.logout(id);
                  if (mounted) {
                    showAppNotify(context, context.l10n.sync_loggedOut,
                        kind: AppNotifyKind.success);
                  }
                },
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: Text(context.l10n.sync_logout),
        ),
      ],
    );
  }

  Widget _form(AppPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          context.l10n.srclogin_intro(_name),
          style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.55),
        ),
        const SizedBox(height: 18),
        AppTextField(
          controller: _userCtrl,
          enabled: !_busy,
          label: context.l10n.srclogin_accountLabel,
          autofillHints: const [AutofillHints.username],
        ),
        const SizedBox(height: 12),
        AppTextField(
          controller: _pwCtrl,
          enabled: !_busy,
          obscure: _obscure,
          label: context.l10n.sync_password,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _busy ? null : _login(),
          suffixIcon: IconButton(
            icon: Icon(
                _obscure
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 20),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: p.statusFail, fontSize: 12.5)),
        ],
        const SizedBox(height: 18),
        FilledButton(
          onPressed: _busy ? null : _login,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.sync_login),
        ),
      ],
    );
  }
}
