import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_info.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
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
      showAppNotify(context, context.l10n.about_enteredDebug,
          kind: AppNotifyKind.success);
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const DebugPage()));
    } else if (_sealTaps >= 3) {
      final left = 5 - _sealTaps;
      showAppNotify(context, context.l10n.about_tapMoreToDebug(left),
          kind: AppNotifyKind.info);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final topInset = MediaQuery.of(context).viewPadding.top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: Text(context.l10n.about,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: EntranceSlide(
        begin: const Offset(0, 0.06),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: AppScrollView(
        padding: const EdgeInsets.fromLTRB(30, 50, 30, 50),
        children: [
          _hero(p),
          const SizedBox(height: 28),
          _section(p, context.l10n.about_intro),
          const SizedBox(height: 10),
          _paragraph(p, context.l10n.about_introBody),
          const SizedBox(height: 24),
          _section(p, context.l10n.about_highlights),
          const SizedBox(height: 10),
          _card(
            p,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final h in _highlights(context)) _bullet(p, h),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _section(p, context.l10n.about_sourcesCount(registeredSources.length)),
          const SizedBox(height: 10),
          _card(
            p,
            Wrap(
              spacing: 8,
              runSpacing: 10,
              alignment: WrapAlignment.center, // 词云式:居中流排、大小错落
              runAlignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final s in registeredSources) _sourceChip(p, s.name),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _section(p, context.l10n.about_links),
          const SizedBox(height: 8),
          AppLinkRow(
            icon: Icons.code_rounded,
            title: context.l10n.about_repo,
            url: AppInfo.repoUrl.replaceFirst('https://', ''),
            onTap: () => _open(context, AppInfo.repoUrl),
          ),
          const SizedBox(height: 24),
          _section(p, context.l10n.about_tech),
          const SizedBox(height: 10),
          _paragraph(p, context.l10n.about_techBody),
          const SizedBox(height: 24),
          _section(p, context.l10n.about_disclaimer),
          const SizedBox(height: 10),
          _paragraph(
            p,
            context.l10n.about_disclaimerBody,
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
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      showAppNotify(context, context.l10n.about_openLinkFailed,
          kind: AppNotifyKind.error);
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
          Text('${AppInfo.cnName} · ${context.l10n.about_tagline}',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.textMuted, fontSize: 12.5)),
          const SizedBox(height: 12),
          AppPill(
            text: 'v${AppInfo.version}',
            fill: p.accent.withValues(alpha: 0.16),
            textColor: p.accent,
            fontSize: 12,
            radius: 20,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          ),
        ],
      );

  // 页内小助手改为委托设计系统组件(去掉手搓样式,call site 不变)。
  Widget _section(AppPalette p, String text) => AppSectionLabel(text);

  Widget _card(AppPalette p, Widget child) => AppCard(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        child: child,
      );

  Widget _paragraph(AppPalette p, String text, {bool muted = false}) => Text(
        text,
        style: TextStyle(
            color: muted ? p.textMuted : p.textPrimary,
            fontSize: 13,
            height: 1.7),
      );

  // 功能亮点(关于页)按当前语言列出;文案在 ARB(about_hl1..11),不再硬编码于 AppInfo。
  List<String> _highlights(BuildContext context) {
    final l = context.l10n;
    return [
      l.about_hl1, l.about_hl2, l.about_hl3, l.about_hl4, l.about_hl5, l.about_hl6,
      l.about_hl7, l.about_hl8, l.about_hl9, l.about_hl10, l.about_hl11,
    ];
  }

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

  // 词云式来源标签:按名字散列做大小 / 强调错落,像词云的高低频词。
  Widget _sourceChip(AppPalette p, String name) {
    final h = name.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0x7fffffff);
    const sizes = [12.0, 13.0, 14.5, 12.5, 16.0, 13.5];
    final fs = sizes[h % sizes.length];
    final accent = h % 3 == 0; // 约三分之一用青碧强调
    return AppPill(
      text: name,
      fill: accent ? p.accent.withValues(alpha: 0.14) : p.elevated,
      border: accent ? p.accent.withValues(alpha: 0.40) : p.line,
      textColor: accent ? p.accent : p.textPrimary,
      fontSize: fs,
      fontWeight: FontWeight.w700,
      radius: 20,
      padding: EdgeInsets.symmetric(
          horizontal: 10 + fs * 0.15, vertical: 4 + fs * 0.15),
    );
  }

}
