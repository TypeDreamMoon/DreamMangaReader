import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/net/app_proxy.dart';
import '../../ui/ui.dart';

/// 网络代理设置:不使用代理 / 使用系统代理 / 自定义,带"测试连接"预演。
class ProxySettingsPage extends StatefulWidget {
  const ProxySettingsPage({super.key});

  @override
  State<ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<ProxySettingsPage> {
  late int _mode; // 0 不使用 · 1 系统 · 2 自定义
  late final TextEditingController _ctrl;
  String _result = '';
  bool _ok = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final ov = AppProxy.override;
    _mode = ov == null ? 1 : (ov == 'DIRECT' ? 0 : 2);
    _ctrl = TextEditingController(
        text: _mode == 2 ? ov : (AppProxy.current ?? '127.0.0.1:7890'));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<String?> _effectiveProxy() async {
    if (_mode == 0) return null; // 直连
    if (_mode == 2) return _ctrl.text.trim();
    return (await AppProxy.detectAuto()).$1; // 系统
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = '测试中…（联网)';
    });
    final p = await _effectiveProxy();
    final (ok, msg) = await AppProxy.test(p);
    if (!mounted) return;
    setState(() {
      _ok = ok;
      _result = msg;
      _testing = false;
    });
  }

  Future<void> _save() async {
    final v = _mode == 0 ? 'DIRECT' : (_mode == 1 ? null : _ctrl.text.trim());
    await AppProxy.setOverride(v);
    if (!mounted) return;
    showAppNotify(context, '代理已保存:${AppProxy.current ?? '直连'}',
        kind: AppNotifyKind.success);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('网络代理',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: AppScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AppCard(
            color: p.elevated,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 18, color: p.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '当前生效:${AppProxy.current ?? '直连'} · ${AppProxy.sourceLabel}',
                    style: TextStyle(color: p.textPrimary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _option(p, 0, Icons.public_off_rounded, '不使用代理',
              '直连,不走任何代理。国内可能访问不了被墙的源。'),
          _option(p, 1, Icons.settings_ethernet_rounded, '使用系统代理',
              '跟随 Windows 系统代理 / 环境变量。开了 FlClash 系统代理就能用(推荐)。'),
          _option(p, 2, Icons.dns_rounded, '自定义代理', '手动指定 host:port。'),
          if (_mode == 2) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 8),
              child: AppTextField(
                controller: _ctrl,
                hint: 'host:port,如 127.0.0.1:7890',
                prefixIcon:
                    Icon(Icons.link_rounded, size: 18, color: p.textMuted),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: p.accent))
                    : const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 14),
            AppCard(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              borderColor: _result.startsWith('测试中')
                  ? p.line
                  : (_ok ? p.statusOk : p.statusFail),
              child: SelectableText(
                _result,
                style:
                    TextStyle(color: p.textPrimary, fontSize: 12.5, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _option(
          AppPalette p, int value, IconData icon, String title, String subtitle) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AppSelectableRow(
          icon: icon,
          title: title,
          subtitle: subtitle,
          selected: _mode == value,
          onTap: () => setState(() => _mode = value),
        ),
      );
}
