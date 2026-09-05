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
  late final TextEditingController _noProxyCtrl;
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
    _noProxyCtrl = TextEditingController(text: AppProxy.noProxy);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _noProxyCtrl.dispose();
    super.dispose();
  }

  /// 解析错误码 → 当前语言文案。核心层只给码,文案在这里。
  String _parseErrorText(AppLocalizations l10n, ProxyParseError e) =>
      switch (e) {
        ProxyParseError.empty => l10n.proxy_errEmpty,
        ProxyParseError.malformed => l10n.proxy_errInvalid,
        ProxyParseError.badPort => l10n.proxy_errPort,
        ProxyParseError.socksUnsupported => l10n.proxy_errSocks,
      };

  /// 自定义模式下把输入框解析成端点;不合法就把原因写进结果卡片并返回 null。
  ProxyParseResult? _parseCustom() {
    final r = AppProxy.parse(_ctrl.text);
    if (r.ok) return r;
    setState(() {
      _ok = false;
      _testing = false;
      _result = _parseErrorText(context.l10n, r.error!);
    });
    return null;
  }

  Future<ProxyEndpoint?> _effectiveProxy() async {
    if (_mode == 0) return null; // 直连
    if (_mode == 2) return _parseCustom()?.endpoint;
    return (await AppProxy.detectAuto()).$1; // 系统
  }

  Future<void> _test() async {
    final l10n = context.l10n;
    // 自定义模式:地址不合法就别浪费 12 秒去连一个解析不出来的东西。
    if (_mode == 2 && _parseCustom() == null) return;
    setState(() {
      _testing = true;
      _result = l10n.proxy_testing;
    });
    final p = await _effectiveProxy();
    final r = await AppProxy.test(
      p,
      bypass: AppProxy.parseNoProxy(_noProxyCtrl.text),
    );
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
    // 存之前先校验:以前什么都收,`socks5://…` 或 `user:pass@host` 存下去后会被
    // 当成主机名硬连,用户只看到「所有源都连不上」,没人猜得到是这里写错了。
    if (_mode == 2 && _parseCustom() == null) return;
    final v = _mode == 0 ? 'DIRECT' : (_mode == 1 ? null : _ctrl.text.trim());
    await AppProxy.setOverride(v, noProxy: _noProxyCtrl.text);
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
          // 直连名单:内网站点 / 本地服务不该被推去绕代理(挂了代理连不上局域网
          // 是很常见的报障)。强制直连模式下没有意义,不展示。
          if (_mode != 0) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                context.l10n.proxy_noProxyLabel,
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: AppTextField(
                controller: _noProxyCtrl,
                hint: context.l10n.proxy_noProxyHint,
                prefixIcon: Icon(Icons.alt_route_rounded,
                    size: 18, color: p.textMuted),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                context.l10n.proxy_noProxySub,
                style: TextStyle(color: p.textMuted, fontSize: 11.5),
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
