import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
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
    final l10n = context.l10n;
    setState(() {
      _testing = true;
      _result = l10n.proxy_testing;
    });
    final p = await _effectiveProxy();
    final r = await AppProxy.test(p);
    if (!mounted) return;
    setState(() {
      _ok = r.ok;
      _result = _testResultText(l10n, r);
      _testing = false;
    });
  }

  /// 结构化测试结果 → 当前语言文案(via 为 null 时显示「直连」)。
  String _testResultText(AppLocalizations l10n, ProxyTestResult r) {
    final via = r.via ?? l10n.proxy_direct;
    return switch (r.kind) {
      ProxyTestKind.ok => l10n.proxy_testOk(r.status, r.ms, via),
      ProxyTestKind.abnormal => l10n.proxy_testAbnormal(r.status, r.ms, via),
      ProxyTestKind.failed => l10n.proxy_testFailed(r.ms, via, r.error ?? ''),
    };
  }

  /// 代理来源码 → 当前语言标签。
  String _sourceText(AppLocalizations l10n, ProxySource s) => switch (s) {
        ProxySource.forcedDirect => l10n.proxy_srcForcedDirect,
        ProxySource.manual => l10n.proxy_srcManual,
        ProxySource.envVar => l10n.proxy_srcEnvVar,
        ProxySource.systemProxy => l10n.proxy_srcSystemProxy,
        ProxySource.directNoProxy => l10n.proxy_srcDirectNoProxy,
      };

  Future<void> _save() async {
    final v = _mode == 0 ? 'DIRECT' : (_mode == 1 ? null : _ctrl.text.trim());
    await AppProxy.setOverride(v);
    if (!mounted) return;
    showAppNotify(
        context, context.l10n.proxy_savedToast(AppProxy.current ?? context.l10n.proxy_direct),
        kind: AppNotifyKind.success);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(context.l10n.proxy_title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
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
                    context.l10n.proxy_current(
                        AppProxy.current ?? context.l10n.proxy_direct,
                        _sourceText(context.l10n, AppProxy.sourceCode)),
                    style: TextStyle(color: p.textPrimary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _option(p, 0, Icons.public_off_rounded, context.l10n.proxy_modeNone,
              context.l10n.proxy_modeNoneSub),
          _option(p, 1, Icons.settings_ethernet_rounded,
              context.l10n.proxy_modeSystem, context.l10n.proxy_modeSystemSub),
          _option(p, 2, Icons.dns_rounded, context.l10n.proxy_modeCustom,
              context.l10n.proxy_modeCustomSub),
          if (_mode == 2) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 8),
              child: AppTextField(
                controller: _ctrl,
                hint: context.l10n.proxy_customHint,
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
                label: Text(context.l10n.sync_testConnection),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text(context.l10n.save),
                ),
              ),
            ],
          ),
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 14),
            AppCard(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              borderColor: _testing
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
