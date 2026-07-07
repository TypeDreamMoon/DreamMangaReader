import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_info.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/app_logo.dart';
import '../debug/debug_page.dart';

/// 关于页:应用信息、功能亮点、漫画源清单、仓库链接、免责声明。
/// 隐藏入口:连点「梦」印章 5 次进入调试工具。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  int _sealTaps = 0;

  void _onSealTap() {
    _sealTaps++;
    if (_sealTaps >= 5) {
      _sealTaps = 0;
      showAppNotify(context, '已进入调试工具', kind: AppNotifyKind.success);
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const DebugPage()));
    } else if (_sealTaps >= 3) {
      final left = 5 - _sealTaps;
      showAppNotify(context, '再点 $left 次进入调试工具', kind: AppNotifyKind.info);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('关于',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          _hero(p),
          const SizedBox(height: 28),
          _section(p, '简介'),
          const SizedBox(height: 10),
          _paragraph(p,
              '一个自制的跨平台漫画阅读器,聚合多个漫画源,统一的浏览 / 搜索 / 阅读体验。'
              '源以沙箱脚本实现,可跨 Android 与 Windows 运行。'),
          const SizedBox(height: 24),
          _section(p, '功能亮点'),
          const SizedBox(height: 10),
          _card(
            p,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final h in AppInfo.highlights) _bullet(p, h),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _section(p, '漫画源 · 共 ${registeredSources.length} 个'),
          const SizedBox(height: 10),
          _card(
            p,
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in registeredSources) _sourceChip(p, s.name),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _section(p, '链接'),
          const SizedBox(height: 8),
          _linkTile(
            p,
            Icons.code_rounded,
            '开源仓库',
            AppInfo.repoUrl.replaceFirst('https://', ''),
            () => _open(context, AppInfo.repoUrl),
          ),
          const SizedBox(height: 24),
          _section(p, '技术'),
          const SizedBox(height: 10),
          _paragraph(p,
              'Flutter(Material 3)· QuickJS 脚本源引擎(prepare/handle 契约,宿主拥有全部 I/O)'
              '· dio / 隐藏 WebView 混合传输。'),
          const SizedBox(height: 24),
          _section(p, '免责声明'),
          const SizedBox(height: 10),
          _paragraph(
            p,
            '本应用不存储、不提供任何漫画内容,所有内容均来自第三方公开站点,版权归原作者及站点所有。'
            '仅供个人学习与技术交流,请勿用于商业用途,并支持正版。若有侵权请联系删除。',
            muted: true,
          ),
          const SizedBox(height: 28),
          Center(
            child: Text(
              '© ${AppInfo.author} · ${AppInfo.name} v${AppInfo.version} · MIT License',
              style: TextStyle(color: p.textMuted, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      showAppNotify(context, '打不开链接,请手动访问仓库地址', kind: AppNotifyKind.error);
    }
  }

  Widget _hero(AppPalette p) => Column(
        children: [
          GestureDetector(
            onTap: _onSealTap,
            behavior: HitTestBehavior.opaque,
            child: const AppLogo(size: 96),
          ),
          const SizedBox(height: 18),
          Text(AppInfo.name,
              style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Text('${AppInfo.cnName} · ${AppInfo.tagline}',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.textMuted, fontSize: 12.5)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('v${AppInfo.version}',
                style: TextStyle(
                    color: p.accent, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      );

  Widget _section(AppPalette p, String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
            color: p.accent,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 2),
      );

  Widget _card(AppPalette p, Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.line),
        ),
        child: child,
      );

  Widget _paragraph(AppPalette p, String text, {bool muted = false}) => Text(
        text,
        style: TextStyle(
            color: muted ? p.textMuted : p.textPrimary,
            fontSize: 13,
            height: 1.7),
      );

  Widget _bullet(AppPalette p, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 10),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
              ),
            ),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: p.textPrimary, fontSize: 13, height: 1.5)),
            ),
          ],
        ),
      );

  Widget _sourceChip(AppPalette p, String name) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: p.elevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.line),
        ),
        child: Text(name,
            style: TextStyle(
                color: p.textPrimary, fontSize: 12.5, fontWeight: FontWeight.w600)),
      );

  Widget _linkTile(AppPalette p, IconData icon, String title, String subtitle,
          VoidCallback onTap) =>
      ListTile(
        tileColor: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.line),
        ),
        leading: Icon(icon, color: p.accent),
        title: Text(title,
            style: TextStyle(
                color: p.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 14)),
        subtitle: Text(subtitle,
            style: TextStyle(color: p.textMuted, fontSize: 12)),
        trailing: Icon(Icons.open_in_new_rounded, size: 18, color: p.textMuted),
        onTap: onTap,
      );
}
