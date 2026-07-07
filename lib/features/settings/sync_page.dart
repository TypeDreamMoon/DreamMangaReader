import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/source_repository.dart';
import '../../core/sync/sync_controller.dart';
import '../../ui/ui.dart';

/// 云同步设置页(WebDAV)。配 地址/账密 → 测试 → 一键同步 / 自动同步。
/// 同步范围:收藏、阅读进度、阅读设置、源开关、源仓库配置。不含每源登录 token 与下载文件。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final _sync = SyncController.instance;
  late final _urlCtrl = TextEditingController(text: _sync.url);
  late final _userCtrl = TextEditingController(text: _sync.username);
  late final _passCtrl = TextEditingController(text: _sync.password);
  late bool _auto = _sync.auto;
  bool _busy = false;
  String _result = '';

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _persist() => _sync.saveConfig(
        url: _urlCtrl.text,
        username: _userCtrl.text,
        password: _passCtrl.text,
        auto: _auto,
      );

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
              '把 收藏 / 阅读进度 / 阅读设置 / 源开关 / 源仓库配置 通过 WebDAV 跨设备同步。'
              '双向合并、不丢收藏与进度(同一条按更新时间取新)。不同步每源登录态与下载文件。',
              style: TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.55),
            ),
          ),
          AppCard(
            radius: 14,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _field(p, _urlCtrl, 'WebDAV 地址',
                    '如 https://dav.jianguoyun.com/dav/'),
                const SizedBox(height: 10),
                _field(p, _userCtrl, '账号', '用户名 / 邮箱'),
                const SizedBox(height: 10),
                _field(p, _passCtrl, '密码', '密码 / 应用授权码', obscure: true),
                const SizedBox(height: 6),
                SwitchListTile(
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
                          _persist();
                        },
                ),
              ],
            ),
          ),
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
          Text('提示:坚果云等需在网页端「安全选项 → 添加应用」生成专用密码,别用登录密码。',
              style: TextStyle(color: p.textMuted, fontSize: 11.5, height: 1.5)),
        ],
      ),
    );
  }

  Widget _field(AppPalette p, TextEditingController c, String label, String hint,
      {bool obscure = false}) {
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
          enabled: !_busy,
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
