import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/net/iam_auth.dart';
import '../../core/sync/sync_controller.dart';
import '../../ui/ui.dart';

/// 打开登录页时停在哪一栏。
enum AuthMode { signIn, signUp }

/// 把一个异常翻成能给用户看的一句话。
///
/// IAM 的信封 `code` 是**稳定契约**(见 [IamErr]),HTTP 状态不是,所以一律按码分。
/// 认不出的码退回服务端原文 —— 宁可显示一句英文,也好过「未知错误」。
///
/// 4001 / 4003 特意分开说:前者是「这个 App 没在 IAM 登记」,后者是「登记了但没
/// 给开这种登录方式」。两者都不是用户能自己解决的,但维护者看一眼就知道去改哪。
String authErrorText(BuildContext context, Object e) {
  final l = context.l10n;
  if (e is IamException) {
    return switch (e.code) {
      IamErr.invalidCredentials => l.authErr_invalidCredentials,
      IamErr.accountExists => l.authErr_accountExists,
      IamErr.accountInactive => l.authErr_accountInactive,
      IamErr.weakPassword => l.auth_badPassword,
      IamErr.invalidUsername => l.auth_badUsername,
      IamErr.codeInvalid => l.authErr_codeInvalid,
      IamErr.codeCooldown => l.authErr_codeCooldown,
      IamErr.codeTooManyAttempts => l.authErr_codeTooMany,
      IamErr.rateLimited => l.authErr_rateLimited,
      IamErr.unknownConsumer => l.authErr_unknownConsumer,
      IamErr.invalidGrant => l.authErr_invalidGrant,
      IamErr.invalidToken || IamErr.refreshReused => l.authErr_invalidToken,
      _ => e.serverMsg,
    };
  }
  if (e is DioException) return l.authErr_network;
  return '$e';
}

/// 账号登录 / 注册 / 找回密码 —— 全部在 App 内完成,不跳浏览器。
///
/// 以前登录要跳系统浏览器走 OIDC 授权码流,代价是:桌面要占一个固定回环端口、
/// 两端各要在 IAM 注册 redirect_uri、用户被甩出应用再甩回来,而且注册和找回密码
/// 根本没有入口。IAM 本来就有一套原生 auth API(`/auth/v1/*`),这页直接用它。
///
/// 登录成功 `Navigator.pop(true)`,调用方据此刷新自己的账号卡片。
class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.initialMode = AuthMode.signIn});

  final AuthMode initialMode;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  late AuthMode _mode = widget.initialMode;

  /// 找回密码是登录栏里岔出去的一步,不是第三个并列的 tab —— 用它盖住表单,
  /// 完事再退回登录栏。
  bool _forgot = false;

  final _account = TextEditingController();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _obscure = true;
  bool _busy = false;
  String? _error; // 表单顶部的错误条(校验不过 / 服务端拒绝)

  Timer? _resendTimer;
  int _resendLeft = 0; // >0 = 冷却中,秒

  IamAuth get _auth => IamAuth.instance;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _account.dispose();
    _email.dispose();
    _code.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  // ---- 动作 ----

  /// 统一的「跑一个会失败的账号动作」:清错、置忙、翻译异常、收忙。
  /// 返回是否成功。
  Future<bool> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = authErrorText(context, e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendLeft = IamAuth.codeResendCooldown.inSeconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendLeft--);
      if (_resendLeft <= 0) t.cancel();
    });
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!IamAuth.isEmail(email)) {
      setState(() => _error = context.l10n.auth_badEmail);
      return;
    }
    final scene = _forgot ? IamCodeScene.reset : IamCodeScene.signup;
    final ok = await _run(() => _auth.sendCode(
          email: email,
          scene: scene,
          // 验证码邮件跟随界面语言。
          locale: Localizations.localeOf(context).languageCode,
        ));
    if (!ok || !mounted) return;
    // 冷却由服务端强制(60s),这里的倒计时只是把它显示出来,免得用户狂点。
    _startResendCooldown();
    showAppNotify(context, context.l10n.auth_codeSent,
        kind: AppNotifyKind.success);
  }

  Future<void> _signIn() async {
    final l = context.l10n;
    if (_account.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = l.authErr_invalidCredentials);
      return;
    }
    final ok = await _run(() => _auth.loginPassword(
          account: _account.text,
          password: _password.text,
        ));
    if (!ok || !mounted) return;
    showAppNotify(context, l.sync_loginSuccess(_auth.username ?? l.sync_account),
        kind: AppNotifyKind.success);
    Navigator.of(context).pop(true);
  }

  Future<void> _signUp() async {
    final l = context.l10n;
    // 本地先按服务端同一套规则挡一道:少一次往返,也少浪费一次验证码。
    // 真正的判定仍在服务端 —— 这里放过去的那边照样会拒。
    final err = !IamAuth.isEmail(_email.text)
        ? l.auth_badEmail
        : _code.text.trim().length != IamAuth.codeLength
            ? l.auth_badCode
            : !IamAuth.isValidUsername(_username.text)
                ? l.auth_badUsername
                : !IamAuth.isValidPassword(_password.text)
                    ? l.auth_badPassword
                    : null;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final ok = await _run(() => _auth.signup(
          email: _email.text,
          code: _code.text,
          username: _username.text,
          password: _password.text,
        ));
    if (!ok || !mounted) return;
    // 服务端注册成功即返回 TokenBundle,已经是登录态,不必再登一次。
    showAppNotify(context, l.auth_signUpOk, kind: AppNotifyKind.success);
    Navigator.of(context).pop(true);
  }

  Future<void> _reset() async {
    final l = context.l10n;
    final err = !IamAuth.isEmail(_email.text)
        ? l.auth_badEmail
        : _code.text.trim().length != IamAuth.codeLength
            ? l.auth_badCode
            : !IamAuth.isValidPassword(_password.text)
                ? l.auth_badPassword
                : null;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final ok = await _run(() => _auth.resetPassword(
          email: _email.text,
          code: _code.text,
          newPassword: _password.text,
        ));
    if (!ok || !mounted) return;
    // 这个接口不发 token,所以回登录栏让用户用新密码登一次。
    showAppNotify(context, l.auth_resetOk, kind: AppNotifyKind.success);
    setState(() {
      _forgot = false;
      _account.text = _email.text.trim();
      _code.clear();
      _password.clear();
    });
  }

  void _switchMode(AuthMode m) {
    if (_mode == m && !_forgot) return;
    setState(() {
      _mode = m;
      _forgot = false;
      _error = null;
      _code.clear();
      _password.clear();
    });
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l = context.l10n;
    final title = _forgot
        ? l.auth_resetTitle
        : (_mode == AuthMode.signUp ? l.auth_tabSignUp : l.auth_tabSignIn);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      ),
      body: AppScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          // 表单整体限宽:桌面窗口拉宽时输入框不该跟着抻成一条横线。
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_forgot) ...[
                      _modeTabs(l),
                      const SizedBox(height: 18),
                    ],
                    ..._fields(p, l),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      _errorBar(p, _error!),
                    ],
                    const SizedBox(height: 18),
                    _submitButton(l),
                    const SizedBox(height: 12),
                    _footerLinks(p, l),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeTabs(AppLocalizations l) => SegmentedButton<AuthMode>(
        segments: [
          ButtonSegment(
              value: AuthMode.signIn,
              label: Text(l.auth_tabSignIn),
              icon: const Icon(Icons.login_rounded, size: 16)),
          ButtonSegment(
              value: AuthMode.signUp,
              label: Text(l.auth_tabSignUp),
              icon: const Icon(Icons.person_add_alt_rounded, size: 16)),
        ],
        selected: {_mode},
        onSelectionChanged: _busy ? null : (s) => _switchMode(s.first),
      );

  List<Widget> _fields(AppPalette p, AppLocalizations l) {
    if (_forgot) {
      return [
        _labelled(p, l.auth_email, _emailField(l)),
        const SizedBox(height: 14),
        _labelled(p, l.auth_code, _codeField(l)),
        const SizedBox(height: 14),
        _labelled(p, l.auth_newPassword,
            _passwordField(l, hint: l.auth_passwordHint, isNew: true)),
      ];
    }
    if (_mode == AuthMode.signUp) {
      return [
        _labelled(p, l.auth_email, _emailField(l)),
        const SizedBox(height: 14),
        _labelled(p, l.auth_code, _codeField(l)),
        const SizedBox(height: 14),
        _labelled(
          p,
          l.sync_username,
          AppTextField(
            controller: _username,
            hint: l.auth_usernameHint,
            enabled: !_busy,
            autofillHints: const [AutofillHints.newUsername],
            textInputAction: TextInputAction.next,
          ),
        ),
        const SizedBox(height: 14),
        _labelled(p, l.sync_password,
            _passwordField(l, hint: l.auth_passwordHint, isNew: true)),
      ];
    }
    return [
      _labelled(
        p,
        l.auth_account,
        AppTextField(
          controller: _account,
          hint: l.auth_accountHint,
          enabled: !_busy,
          autofocus: true,
          // 账号位邮箱和用户名都收,所以不能锁成 emailAddress 键盘。
          autofillHints: const [AutofillHints.username],
          textInputAction: TextInputAction.next,
        ),
      ),
      const SizedBox(height: 14),
      _labelled(p, l.sync_password, _passwordField(l, onSubmit: _signIn)),
    ];
  }

  Widget _emailField(AppLocalizations l) => AppTextField(
        controller: _email,
        hint: l.auth_emailHint,
        enabled: !_busy,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        textInputAction: TextInputAction.next,
      );

  /// 验证码输入 + 右侧发码按钮。冷却中按钮变成倒计时并禁用。
  Widget _codeField(AppLocalizations l) => Row(
        children: [
          Expanded(
            child: AppTextField(
              controller: _code,
              hint: l.auth_codeHint,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              textInputAction: TextInputAction.next,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 116,
            height: 44,
            child: OutlinedButton(
              onPressed: (_busy || _resendLeft > 0) ? null : _sendCode,
              child: Text(
                _resendLeft > 0 ? l.auth_resendIn(_resendLeft) : l.auth_sendCode,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ),
        ],
      );

  Widget _passwordField(AppLocalizations l,
          {String? hint, bool isNew = false, VoidCallback? onSubmit}) =>
      AppTextField(
        controller: _password,
        // 登录栏不提示密码策略(那是注册时的事),所以 hint 可以为空。
        hint: hint,
        obscure: _obscure,
        enabled: !_busy,
        autofillHints: [isNew ? AutofillHints.newPassword : AutofillHints.password],
        textInputAction: onSubmit != null ? TextInputAction.done : TextInputAction.next,
        onSubmitted: onSubmit == null ? null : (_) => onSubmit(),
        suffixIcon: IconButton(
          tooltip: _obscure ? l.sync_showPassword : l.sync_hidePassword,
          icon: Icon(
              _obscure
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
              size: 20),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      );

  Widget _labelled(AppPalette p, String label, Widget field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          field,
        ],
      );

  Widget _errorBar(AppPalette p, String message) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: p.statusFail.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.statusFail.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 17, color: p.statusFail),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: TextStyle(
                      color: p.textPrimary, fontSize: 12.5, height: 1.45)),
            ),
          ],
        ),
      );

  Widget _submitButton(AppLocalizations l) {
    final (label, action) = switch ((_forgot, _mode)) {
      (true, _) => (l.auth_resetTitle, _reset),
      (false, AuthMode.signUp) => (l.auth_tabSignUp, _signUp),
      (false, AuthMode.signIn) => (l.auth_tabSignIn, _signIn),
    };
    return SizedBox(
      height: 46,
      child: FilledButton(
        onPressed: _busy ? null : action,
        child: _busy
            ? const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Text(label,
                style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
  }

  Widget _footerLinks(AppPalette p, AppLocalizations l) {
    if (_forgot) {
      return Center(
        child: TextButton(
          onPressed: _busy ? null : () => setState(() {
                _forgot = false;
                _error = null;
              }),
          child: Text(l.auth_toSignIn),
        ),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        TextButton(
          onPressed: _busy
              ? null
              : () => _switchMode(_mode == AuthMode.signIn
                  ? AuthMode.signUp
                  : AuthMode.signIn),
          child: Text(_mode == AuthMode.signIn ? l.auth_toSignUp : l.auth_toSignIn),
        ),
        if (_mode == AuthMode.signIn)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _forgot = true;
                      _error = null;
                      _code.clear();
                      _password.clear();
                    }),
            child: Text(l.auth_forgot),
          ),
      ],
    );
  }
}

/// 打开登录页。返回 true = 已登录(调用方据此刷新)。
///
/// 地址不再有「Custom」一说,进来前统一把官方常量灌进 [IamAuth] —— 老版本可能
/// 存过自建地址,不覆盖的话这次登录会打到那台已经不用的服务上。
Future<bool> openAuthPage(BuildContext context,
    {AuthMode mode = AuthMode.signIn}) async {
  IamAuth.instance.configure(
    issuer: SyncController.hzPresetIssuer,
    clientId: SyncController.hzPresetClientId,
  );
  final ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => AuthPage(initialMode: mode)),
  );
  return ok ?? false;
}
