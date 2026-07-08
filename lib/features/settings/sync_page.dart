import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/source_repository.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/sync/sync_data.dart';
import '../../ui/ui.dart';

/// 同步内容类别的中文名(页面与下载弹窗共用)。
const Map<SyncCategory, String> kCatLabels = {
  SyncCategory.favorites: '收藏',
  SyncCategory.history: '阅读进度',
  SyncCategory.settings: '阅读设置',
  SyncCategory.mangaSources: '漫画源',
  SyncCategory.animeSources: '番剧源',
  SyncCategory.sourceRepo: '源仓库',
};

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
      showAppNotify(context, '登录成功:${_sync.auth.username ?? '账号'}',
          kind: AppNotifyKind.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loginBusy = false);
      showAppNotify(context, '登录失败:$e', kind: AppNotifyKind.error);
    }
  }

  Future<void> _logout() async {
    await _sync.auth.logout();
    if (!mounted) return;
    setState(() {});
    showAppNotify(context, '已退出登录', kind: AppNotifyKind.success);
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
      showAppNotify(context, '上传失败:$e', kind: AppNotifyKind.error);
    }
  }

  /// 下载:弹窗选类别 + 覆盖/追加 → 服务器 → 本地。
  Future<void> _download() async {
    final lib = LibraryScope.of(context);
    final res = await showDialog<(Set<SyncCategory>, bool)>(
      context: context,
      builder: (_) => _DownloadDialog(initial: _sync.syncCategories),
    );
    if (res == null || !mounted) return;
    setState(() {
      _busy = true;
      _result = '';
    });
    await _persist();
    try {
      final s = await _sync.downloadNow(lib, SourceRepository.instance,
          categories: res.$1, append: res.$2);
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
      showAppNotify(context, '下载失败:$e', kind: AppNotifyKind.error);
    }
  }

  String _lastLabel() {
    if (_sync.lastSyncedAt == 0) return '尚未同步';
    final d = DateTime.fromMillisecondsSinceEpoch(_sync.lastSyncedAt);
    String two(int n) => n.toString().padLeft(2, '0');
    return '上次同步 ${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isHertz = _kind == 'hertz';
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('云同步',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              '把 收藏 / 阅读进度 / 阅读设置 / 漫画源·番剧源开关 / 源仓库配置 跨设备同步。'
              '上传=本地推到服务器,下载=服务器拉到本地(可选覆盖或追加)。不含每源登录态与下载文件。',
              style: TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.55),
            ),
          ),
          // 后端切换
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'webdav',
                  label: Text('WebDAV'),
                  icon: Icon(Icons.folder_shared_rounded, size: 17)),
              ButtonSegment(
                  value: 'hertz',
                  label: Text('账号'),
                  icon: Icon(Icons.account_circle_rounded, size: 17)),
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
                  label: const Text('上传'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _download,
                  icon: const Icon(Icons.cloud_download_rounded, size: 18),
                  label: const Text('下载'),
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
              label: const Text('测试连接'),
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
            isHertz
                ? '提示:账号数据存自建的 dreamreader-sync 服务。Hertz Service=官方服务(浏览器登录);'
                    'Custom=自建 IAM,用账号密码登录(该 client 需允许密码授权)。'
                : '提示:坚果云等需在网页端「安全选项 → 添加应用」生成专用密码,别用登录密码。',
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
            _field(p, _urlCtrl, 'WebDAV 地址', '如 https://dav.jianguoyun.com/dav/'),
            const SizedBox(height: 10),
            _field(p, _userCtrl, '账号', '用户名 / 邮箱'),
            const SizedBox(height: 10),
            _field(p, _passCtrl, '密码', '密码 / 应用授权码', obscure: true),
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
                  value: 'custom',
                  label: Text('Custom'),
                  icon: Icon(Icons.tune_rounded, size: 16)),
              ButtonSegment(
                  value: 'hertz',
                  label: Text('Hertz Service'),
                  icon: Icon(Icons.verified_rounded, size: 16)),
            ],
            selected: {_preset},
            onSelectionChanged:
                (_busy || _loginBusy) ? null : (s) => _onPreset(s.first),
          ),
          const SizedBox(height: 12),
          // Custom 才显示地址三项;Hertz Service 地址已内置,直接给登录。
          if (!isHertzPreset) ...[
            _field(p, _hSyncCtrl, '同步服务地址', '如 https://sync.yourhost.com'),
            const SizedBox(height: 10),
            _field(p, _hIssuerCtrl, 'IAM 地址', '如 https://iam.yourhost.com'),
            const SizedBox(height: 10),
            _field(p, _hClientCtrl, 'client_id', '你的 IAM client_id'),
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
                  child: Text('已登录:${_sync.auth.username ?? '账号'}',
                      style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: _loginBusy ? null : _logout,
                  child: const Text('退出登录'),
                ),
              ],
            )
          else if (isHertzPreset) ...[
            Text('用系统浏览器打开官方 IAM 登录页,授权后自动返回(密码不经过 App)。',
                style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5)),
            const SizedBox(height: 12),
            _loginButton(p, '浏览器登录', Icons.open_in_browser_rounded),
          ] else ...[
            _field(p, _loginUserCtrl, '用户名', '账号 / 用户名'),
            const SizedBox(height: 10),
            _field(p, _loginPassCtrl, '密码', '登录密码', obscure: true),
            const SizedBox(height: 12),
            _loginButton(p, '登录', Icons.login_rounded),
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
            Text('同步内容(上传范围)',
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('上传只推勾选的类别;下载时可在弹窗里单独再选。',
                style: TextStyle(color: p.textMuted, fontSize: 11.5, height: 1.4)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final c in SyncCategory.values)
                  FilterChip(
                    label: Text(kCatLabels[c]!),
                    selected: _sync.syncCategories.contains(c),
                    onSelected: _busy
                        ? null
                        : (v) {
                            _sync.setSyncCategory(c, v);
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
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _auto,
          activeThumbColor: p.accent,
          title: Text('启动时自动同步',
              style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          subtitle: Text('每次打开 App 后台双向合并一次(不丢本地)',
              style: TextStyle(color: p.textMuted, fontSize: 12)),
          onChanged: _busy
              ? null
              : (v) {
                  setState(() => _auto = v);
                  _sync.setAuto(v);
                },
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
        TextField(
          controller: c,
          enabled: enabled && !_busy,
          obscureText: obscure,
          style: TextStyle(color: p.textPrimary, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(color: p.textMuted, fontSize: 12.5),
            filled: true,
            fillColor: p.background,
            contentPadding:
                const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: p.line)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: p.accent)),
          ),
        ),
      ],
    );
  }
}

/// 下载弹窗:选要下载的类别 + 覆盖/追加模式。确定返回 (类别集合, 是否追加)。
class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.initial});
  final Set<SyncCategory> initial;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  late final Set<SyncCategory> _sel = {...widget.initial};
  bool _append = false; // false=覆盖 · true=追加

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text('从服务器下载',
          style: TextStyle(
              color: p.textPrimary, fontSize: 17, fontWeight: FontWeight.w800)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载哪些内容',
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final c in SyncCategory.values)
                  FilterChip(
                    label: Text(kCatLabels[c]!),
                    selected: _sel.contains(c),
                    onSelected: (v) => setState(
                        () => v ? _sel.add(c) : _sel.remove(c)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('方式',
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: false,
                    label: Text('覆盖'),
                    icon: Icon(Icons.sync_alt_rounded, size: 16)),
                ButtonSegment(
                    value: true,
                    label: Text('追加'),
                    icon: Icon(Icons.playlist_add_rounded, size: 16)),
              ],
              selected: {_append},
              onSelectionChanged: (s) => setState(() => _append = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _append
                  ? '追加:收藏/源开关取并集,阅读设置与源仓库保持本地不变——不丢本地数据。'
                  : '覆盖:所选类别用服务器的替换本地(未勾的类别不动)。',
              style: TextStyle(color: p.textMuted, fontSize: 11.5, height: 1.45),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _sel.isEmpty
              ? null
              : () => Navigator.of(context).pop((_sel, _append)),
          child: const Text('下载'),
        ),
      ],
    );
  }
}
