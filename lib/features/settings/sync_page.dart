import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/source_repository.dart';
import '../../core/sync/sync_controller.dart';
import '../../ui/ui.dart';

/// 云同步设置页。两种后端可切换:
///   - WebDAV:配 地址/账密。
///   - 账号:登录 IAM 账号,数据存自建 dreamreader-sync(ETag 乐观并发)。
/// 同步范围:收藏、阅读进度、阅读设置、源开关、源仓库配置。不含每源登录 token 与下载文件。
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
  // 账号服务
  late final _hSyncCtrl = TextEditingController(text: _sync.hertzSyncUrl);
  late final _hIssuerCtrl = TextEditingController(text: _sync.hertzIssuer);
  late final _hClientCtrl = TextEditingController(text: _sync.hertzClientId);

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

  Future<void> _login() async {
    setState(() => _loginBusy = true);
    // 登录前先把地址/client 落盘,IamAuth 才有正确的 issuer/clientId。
    await _sync.saveHertzConfig(
      syncUrl: _hSyncCtrl.text,
      issuer: _hIssuerCtrl.text,
      clientId: _hClientCtrl.text,
    );
    try {
      await _sync.auth.loginBrowser();
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

  Future<void> _syncNow() async {
    final lib = LibraryScope.of(context); // 在 await 前取,避免跨异步用 context
    setState(() {
      _busy = true;
      _result = '';
    });
    await _persist();
    try {
      final s = await _sync.syncNow(lib, SourceRepository.instance);
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
      showAppNotify(context, '同步失败:$e', kind: AppNotifyKind.error);
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
              '把 收藏 / 阅读进度 / 阅读设置 / 源开关 / 源仓库配置 跨设备同步。'
              '双向合并、不丢收藏与进度(同一条按更新时间取新)。不同步每源登录态与下载文件。',
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
          _autoCard(p),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _test,
                  icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                  label: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _syncNow,
                  icon: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cloud_sync_rounded, size: 18),
                  label: const Text('立即同步'),
                ),
              ),
            ],
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
                ? '提示:账号同步需要自建的 dreamreader-sync 服务,并在 IAM 里把 client(默认 dreamreader)'
                    '开启 密码 + 刷新令牌 授权。账号在 IAM 网页端注册。'
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
    final locked = _preset == 'hertz';
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
          _field(p, _hSyncCtrl, '同步服务地址', '如 https://sync.yourhost.com',
              enabled: !locked),
          const SizedBox(height: 10),
          _field(p, _hIssuerCtrl, 'IAM 地址', '如 https://iam.yourhost.com',
              enabled: !locked),
          const SizedBox(height: 10),
          _field(p, _hClientCtrl, 'client_id', '默认 dreamreader',
              enabled: !locked),
          if (locked) ...[
            const SizedBox(height: 8),
            Text('已选官方 Hertz Service,地址已锁定。',
                style: TextStyle(color: p.textMuted, fontSize: 11.5)),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: p.line),
          ),
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
          else ...[
            Text('用系统浏览器打开 IAM 登录页,授权后自动返回 App(密码不经过 App)。',
                style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loginBusy ? null : _login,
                icon: _loginBusy
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.open_in_browser_rounded, size: 18),
                label: const Text('浏览器登录'),
              ),
            ),
          ],
        ],
      ),
    );
  }

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
          subtitle: Text('每次打开 App 后台合并一次',
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
