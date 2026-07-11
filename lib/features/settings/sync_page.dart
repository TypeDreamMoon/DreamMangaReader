import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/source_repository.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/sync/sync_data.dart';
import '../../ui/ui.dart';

/// 同步内容类别的本地化名(页面与下载弹窗共用)。多语言下不能是 const map,
/// 走 context.l10n(阅读设置类别复用阅读器的 reader_settings)。
String kCatLabel(BuildContext context, SyncCategory c) {
  final l = context.l10n;
  return switch (c) {
    SyncCategory.favorites => l.sync_catFavorites,
    SyncCategory.history => l.sync_catHistory,
    SyncCategory.searchHistory => l.sync_catSearchHistory,
    SyncCategory.readerSettings => l.reader_settings,
    SyncCategory.uiSettings => l.sync_catUiSettings,
    SyncCategory.appSettings => l.sync_catAppSettings,
    SyncCategory.mangaSources => l.sync_catMangaSources,
    SyncCategory.animeSources => l.sync_catAnimeSources,
    SyncCategory.sourceRepo => l.sync_catSourceRepo,
  };
}

/// 云同步设置页。后端可切 WebDAV / 账号(Hertz Service 官方 或 Custom 自建)。
/// 同步方式:上传(本地→服务器)/ 下载(服务器→本地,可选类别 + 覆盖/追加)。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final _sync = SyncController.instance;

  // WebDAV
  late final _urlCtrl = TextEditingController(text: _sync.url);
  late final _userCtrl = TextEditingController(text: _sync.username);
  late final _passCtrl = TextEditingController(text: _sync.password);
  // 账号服务(Custom）地址
  late final _hSyncCtrl = TextEditingController(text: _sync.hertzSyncUrl);
  late final _hIssuerCtrl = TextEditingController(text: _sync.hertzIssuer);
  late final _hClientCtrl = TextEditingController(text: _sync.hertzClientId);
  // Custom 密码登录
  final _loginUserCtrl = TextEditingController();
  final _loginPassCtrl = TextEditingController();

  late String _kind = _sync.backendKind;
  late String _preset = _sync.hertzPreset; // 'custom' | 'hertz'
  late bool _auto = _sync.auto;
  bool _busy = false;
  bool _loginBusy = false;
  String _result = '';

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _hSyncCtrl.dispose();
    _hIssuerCtrl.dispose();
    _hClientCtrl.dispose();
    _loginUserCtrl.dispose();
    _loginPassCtrl.dispose();
    super.dispose();
  }

  /// 把当前 UI 配置落盘(选定后端 + 该后端的字段 + 自动开关)。
  Future<void> _persist() async {
    await _sync.setBackendKind(_kind);
    if (_kind == 'hertz') {
      await _sync.saveHertzConfig(
        syncUrl: _hSyncCtrl.text,
        issuer: _hIssuerCtrl.text,
        clientId: _hClientCtrl.text,
      );
      await _sync.setAuto(_auto);
    } else {
      await _sync.saveConfig(
        url: _urlCtrl.text,
        username: _userCtrl.text,
        password: _passCtrl.text,
        auto: _auto,
      );
    }
  }

  /// 登录:Hertz 走浏览器 OAuth;Custom 走用户名/密码。
  Future<void> _login() async {
    setState(() => _loginBusy = true);
    await _sync.saveHertzConfig(
      syncUrl: _hSyncCtrl.text,
      issuer: _hIssuerCtrl.text,
      clientId: _hClientCtrl.text,
    );
    try {
      if (_preset == 'hertz') {
        await _sync.auth.loginBrowser();
      } else {
        await _sync.auth.loginPassword(_loginUserCtrl.text, _loginPassCtrl.text);
        _loginPassCtrl.clear();
      }
      if (!mounted) return;
      setState(() => _loginBusy = false);
      showAppNotify(
          context, context.l10n.sync_loginSuccess(_sync.auth.username ?? context.l10n.sync_account),
          kind: AppNotifyKind.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loginBusy = false);
      showAppNotify(context, context.l10n.sync_loginFailed('$e'), kind: AppNotifyKind.error);
    }
  }

  Future<void> _logout() async {
    await _sync.auth.logout();
    if (!mounted) return;
    setState(() {});
    showAppNotify(context, context.l10n.sync_loggedOut, kind: AppNotifyKind.success);
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _result = '';
    });
    await _persist();
    final (ok, msg) = await _sync.testConnection();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = msg;
    });
    showAppNotify(context, msg,
        kind: ok ? AppNotifyKind.success : AppNotifyKind.error);
  }

  /// 上传:本地(勾选的类别)→ 服务器。
  Future<void> _upload() async {
    final lib = LibraryScope.of(context);
    setState(() {
      _busy = true;
      _result = '';
    });
    await _persist();
    try {
      final s = await _sync.uploadNow(lib, SourceRepository.instance);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = s;
      });
      showAppNotify(context, s, kind: AppNotifyKind.success);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = '$e';
      });
      showAppNotify(context, context.l10n.sync_uploadFailed('$e'), kind: AppNotifyKind.error);
    }
  }

  /// 下载:弹窗逐类别选 跳过/覆盖/追加 → 服务器 → 本地。
  Future<void> _download() async {
    final lib = LibraryScope.of(context);
    final modes = await showDialog<Map<SyncCategory, bool>>(
      context: context,
      builder: (_) => _DownloadDialog(initial: _sync.syncCategories),
    );
    if (modes == null || !mounted) return;
    setState(() {
      _busy = true;
      _result = '';
    });
    await _persist();
    try {
      final s = await _sync.downloadNow(lib, SourceRepository.instance,
          modes: modes);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = s;
      });
      showAppNotify(context, s, kind: AppNotifyKind.success);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = '$e';
      });
      showAppNotify(context, context.l10n.sync_downloadFailed('$e'), kind: AppNotifyKind.error);
    }
  }

  String _lastLabel() {
    if (_sync.lastSyncedAt == 0) return context.l10n.sync_neverSynced;
    final d = DateTime.fromMillisecondsSinceEpoch(_sync.lastSyncedAt);
    String two(int n) => n.toString().padLeft(2, '0');
    final ts =
        '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
    return context.l10n.sync_lastSyncedAt(ts);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isHertz = _kind == 'hertz';
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(context.l10n.sync_title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: AppScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              context.l10n.sync_intro,
              style: TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.55),
            ),
          ),
          // 后端切换
          SegmentedButton<String>(
            segments: [
              const ButtonSegment(
                  value: 'webdav',
                  label: Text('WebDAV'),
                  icon: Icon(Icons.folder_shared_rounded, size: 17)),
              ButtonSegment(
                  value: 'hertz',
                  label: Text(context.l10n.sync_account),
                  icon: const Icon(Icons.account_circle_rounded, size: 17)),
            ],
            selected: {_kind},
            onSelectionChanged: _busy
                ? null
                : (s) {
                    setState(() => _kind = s.first);
                    _sync.setBackendKind(_kind);
                  },
          ),
          const SizedBox(height: 12),
          if (isHertz) _hertzCard(p) else _webdavCard(p),
          const SizedBox(height: 12),
          _scopeCard(p),
          const SizedBox(height: 12),
          _autoCard(p),
          const SizedBox(height: 12),
          // 上传 / 下载
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _upload,
                  icon: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cloud_upload_rounded, size: 18),
                  label: Text(context.l10n.sync_upload),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _download,
                  icon: const Icon(Icons.cloud_download_rounded, size: 18),
                  label: Text(context.l10n.sync_download),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
              label: Text(context.l10n.sync_testConnection),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.history_rounded, size: 15, color: p.textMuted),
              const SizedBox(width: 6),
              Text(_lastLabel(),
                  style: TextStyle(color: p.textMuted, fontSize: 12)),
            ],
          ),
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(_result,
                style: TextStyle(
                    color: p.textPrimary, fontSize: 12.5, height: 1.5)),
          ],
          const SizedBox(height: 20),
          Text(
            isHertz ? context.l10n.sync_hertzHint : context.l10n.sync_webdavHint,
            style: TextStyle(color: p.textMuted, fontSize: 11.5, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _webdavCard(AppPalette p) => AppCard(
        radius: 14,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(p, _urlCtrl, context.l10n.sync_webdavUrl,
                context.l10n.sync_webdavUrlHint),
            const SizedBox(height: 10),
            _field(p, _userCtrl, context.l10n.sync_account,
                context.l10n.sync_userHint),
            const SizedBox(height: 10),
            _field(p, _passCtrl, context.l10n.sync_password,
                context.l10n.sync_passwordHint, obscure: true),
          ],
        ),
      );

  void _onPreset(String v) {
    setState(() {
      _preset = v;
      if (v == 'hertz') {
        _hSyncCtrl.text = SyncController.hzPresetSyncUrl;
        _hIssuerCtrl.text = SyncController.hzPresetIssuer;
        _hClientCtrl.text = SyncController.hzPresetClientId;
      }
    });
    _sync.setHertzPreset(v);
  }

  Widget _hertzCard(AppPalette p) {
    final loggedIn = _sync.auth.isLoggedIn;
    final isHertzPreset = _preset == 'hertz';
    return AppCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'hertz',
                  label: Text('Hertz Service'),
                  icon: Icon(Icons.verified_rounded, size: 16)),
              ButtonSegment(
                  value: 'custom',
                  label: Text('Custom'),
                  icon: Icon(Icons.tune_rounded, size: 16)),
            ],
            selected: {_preset},
            onSelectionChanged:
                (_busy || _loginBusy) ? null : (s) => _onPreset(s.first),
          ),
          const SizedBox(height: 12),
          // Custom 才显示地址三项;Hertz Service 地址已内置,直接给登录。
          if (!isHertzPreset) ...[
            _field(p, _hSyncCtrl, context.l10n.sync_serviceUrl,
                context.l10n.sync_serviceUrlHint),
            const SizedBox(height: 10),
            _field(p, _hIssuerCtrl, context.l10n.sync_iamUrl,
                context.l10n.sync_iamUrlHint),
            const SizedBox(height: 10),
            _field(p, _hClientCtrl, 'client_id', context.l10n.sync_clientIdHint),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1, color: p.line),
            ),
          ] else
            const SizedBox(height: 2),
          if (loggedIn)
            Row(
              children: [
                Icon(Icons.check_circle_rounded, size: 18, color: p.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      context.l10n.sync_loggedInAs(
                          _sync.auth.username ?? context.l10n.sync_account),
                      style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: _loginBusy ? null : _logout,
                  child: Text(context.l10n.sync_logout),
                ),
              ],
            )
          else if (isHertzPreset) ...[
            Text(context.l10n.sync_browserLoginHint,
                style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5)),
            const SizedBox(height: 12),
            _loginButton(p, context.l10n.sync_browserLogin,
                Icons.open_in_browser_rounded),
          ] else ...[
            _field(p, _loginUserCtrl, context.l10n.sync_username,
                context.l10n.sync_usernameHint),
            const SizedBox(height: 10),
            _field(p, _loginPassCtrl, context.l10n.sync_password,
                context.l10n.sync_loginPasswordHint, obscure: true),
            const SizedBox(height: 12),
            _loginButton(p, context.l10n.sync_login, Icons.login_rounded),
          ],
        ],
      ),
    );
  }

  Widget _loginButton(AppPalette p, String label, IconData icon) => SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _loginBusy ? null : _login,
          icon: _loginBusy
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 18),
          label: Text(label),
        ),
      );

  Widget _scopeCard(AppPalette p) => AppCard(
        radius: 14,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.sync_scopeTitle,
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(context.l10n.sync_scopeSubtitle,
                style: TextStyle(color: p.textMuted, fontSize: 11.5, height: 1.4)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final c in SyncCategory.values)
                  AppFilterChip(
                    label: kCatLabel(context, c),
                    selected: _sync.syncCategories.contains(c),
                    onTap: _busy
                        ? () {}
                        : () {
                            final sel = _sync.syncCategories.contains(c);
                            _sync.setSyncCategory(c, !sel);
                            setState(() {});
                          },
                  ),
              ],
            ),
          ],
        ),
      );

  Widget _autoCard(AppPalette p) => AppCard(
        radius: 14,
        padding: EdgeInsets.zero, // 让 AppSwitchRow 的 contentPadding 独当留白,避免双重内缩
        child: Column(
          children: [
            AppSwitchRow(
              dense: true,
              contentPadding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
              title: context.l10n.sync_autoOnLaunch,
              titleWeight: FontWeight.w600,
              subtitle: context.l10n.sync_autoOnLaunchSub,
              value: _auto,
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() => _auto = v);
                      _sync.setAuto(v);
                    },
            ),
            Divider(height: 1, thickness: 1, color: p.line),
            // 变化后自动上传:每个需要同步的内容各一个开关,勾了谁、谁在本机
            // 变化后就自动上传谁(只推该类别,不动云端其它内容)。
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.sync_autoUploadTitle,
                      style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(context.l10n.sync_autoUploadSubtitle,
                      style: TextStyle(
                          color: p.textMuted, fontSize: 11.5, height: 1.4)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    children: [
                      for (final c in SyncCategory.values)
                        AppFilterChip(
                          label: kCatLabel(context, c),
                          selected: _sync.autoUploadOn.contains(c),
                          onTap: _busy
                              ? () {}
                              : () {
                                  final sel = _sync.autoUploadOn.contains(c);
                                  _sync.setAutoUploadOn(c, !sel);
                                  setState(() {});
                                },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _field(AppPalette p, TextEditingController c, String label, String hint,
      {bool obscure = false, bool enabled = true}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: p.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        AppTextField(
          controller: c,
          hint: hint,
          obscure: obscure,
          enabled: enabled && !_busy,
        ),
      ],
    );
  }
}

/// 下载单类的方式。
enum _DlMode { skip, overwrite, append }

/// 下载弹窗:逐类别选 跳过 / 覆盖 / 追加。确定返回 {类别: 是否追加}(跳过的不含)。
class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.initial});
  final Set<SyncCategory> initial;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  // 默认:同步内容里勾了的 → 覆盖;没勾的 → 跳过。
  late final Map<SyncCategory, _DlMode> _mode = {
    for (final c in SyncCategory.values)
      c: widget.initial.contains(c) ? _DlMode.overwrite : _DlMode.skip,
  };

  void _setAll(_DlMode m) => setState(() {
        for (final c in SyncCategory.values) {
          _mode[c] = (m == _DlMode.append && !SyncData.supportsAppend(c))
              ? _DlMode.overwrite // 不支持追加的类别退化为覆盖
              : m;
        }
      });

  List<ButtonSegment<_DlMode>> _segments(SyncCategory c) => [
        ButtonSegment(value: _DlMode.skip, label: Text(context.l10n.sync_skip)),
        ButtonSegment(
            value: _DlMode.overwrite, label: Text(context.l10n.sync_overwrite)),
        if (SyncData.supportsAppend(c))
          ButtonSegment(
              value: _DlMode.append, label: Text(context.l10n.sync_append)),
      ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final any = _mode.values.any((m) => m != _DlMode.skip);
    return AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(context.l10n.sync_downloadDialogTitle,
          style: TextStyle(
              color: p.textPrimary, fontSize: 17, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(context.l10n.sync_all,
                      style: TextStyle(color: p.textMuted, fontSize: 12)),
                  _quick(p, context.l10n.sync_skip, () => _setAll(_DlMode.skip)),
                  _quick(p, context.l10n.sync_overwrite,
                      () => _setAll(_DlMode.overwrite)),
                  _quick(p, context.l10n.sync_append,
                      () => _setAll(_DlMode.append)),
                ],
              ),
              const SizedBox(height: 2),
              for (final c in SyncCategory.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 78, // 容中文标签;英文等较长的会自然换行到 2 行
                        child: Text(kCatLabel(context, c),
                            style: TextStyle(
                                color: p.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: SegmentedButton<_DlMode>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle:
                                WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                          ),
                          segments: _segments(c),
                          selected: {_mode[c]!},
                          onSelectionChanged: (s) =>
                              setState(() => _mode[c] = s.first),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Text(
                context.l10n.sync_downloadModeHint,
                style:
                    TextStyle(color: p.textMuted, fontSize: 11.5, height: 1.45),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: any
              ? () => Navigator.of(context).pop(<SyncCategory, bool>{
                    for (final e in _mode.entries)
                      if (e.value != _DlMode.skip)
                        e.key: e.value == _DlMode.append,
                  })
              : null,
          child: Text(context.l10n.sync_download),
        ),
      ],
    );
  }

  Widget _quick(AppPalette p, String label, VoidCallback onTap) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            visualDensity: VisualDensity.compact),
        child: Text(label, style: const TextStyle(fontSize: 12.5)),
      );
}
