import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/update/update_service.dart';
import '../../ui/glass.dart';
import '../../ui/tab_entrance.dart';
import '../discovery/discovery_page.dart';
import '../downloads/downloads_page.dart';
import '../library/library_page.dart';
import '../settings/settings_page.dart';

/// 底部导航外壳:书架 / 发现 / 下载 / 设置。
/// 响应式:宽屏(横屏/桌面)用左侧 NavigationRail,窄屏(竖屏)用底部 NavigationBar。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  final Set<int> _built = {0}; // 懒加载:只构建访问过的页,减轻启动 + 语义树负担

  // 切页动画:IndexedStack 保留各页状态,切换时让新页「淡入 + 轻微上滑」。
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300));
  late final Animation<double> _t =
      CurvedAnimation(parent: _ac, curve: Curves.easeOutCubic);

  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    _ac.value = 1; // 首屏不做动画
    // 启动后台检查更新(设置里可关)。延后一点等存档加载、不抢启动资源。
    // 用可取消的 Timer(而非 Future.delayed)以便 dispose 时清掉,避免测试里挂起。
    _updateTimer = Timer(const Duration(seconds: 3), _maybeCheckUpdate);
  }

  Future<void> _maybeCheckUpdate() async {
    if (!mounted) return;
    final lib = LibraryScope.read(context);
    if (!lib.autoCheckUpdate) return;
    final info = await UpdateService.check(includeBeta: lib.updateIncludeBeta);
    if (info != null && mounted) await showUpdateDialog(context, info);
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _ac.dispose();
    super.dispose();
  }

  static const _pages = [
    LibraryPage(),
    DiscoveryPage(),
    DownloadsPage(),
    SettingsPage(),
  ];

  static const _dests = [
    (Icons.collections_bookmark_outlined, Icons.collections_bookmark_rounded, '书架'),
    (Icons.explore_outlined, Icons.explore_rounded, '发现'),
    (Icons.download_outlined, Icons.download_rounded, '下载'),
    (Icons.settings_outlined, Icons.settings_rounded, '设置'),
  ];

  void _select(int i) {
    if (i == _index) return;
    setState(() {
      _index = i;
      _built.add(i);
    });
    if (LibraryStore.animationsEnabled) {
      _ac.forward(from: 0);
    } else {
      _ac.value = 1; // 关动画:直接到位
    }
  }

  @override
  Widget build(BuildContext context) {
    // 切页入场只做整页淡入;方向性平移交给各页(标题栏落下、内容升起,见 TabEntrance),
    // 不再整页统一上移——否则标题栏也跟着一起上移,做不出「上下对开」。
    final body = FadeTransition(
      opacity: _t.drive(Tween(begin: 0.4, end: 1)),
      child: TabEntrance(
        animation: _t,
        child: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < _pages.length; i++)
              _built.contains(i) ? _pages[i] : const SizedBox.shrink(),
          ],
        ),
      ),
    );
    final p = context.palette;
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 640; // 横屏/桌面
        if (wide) {
          return Scaffold(
            body: Row(
              children: [
                // Row 布局下导轨身后无内容 → 只做半透明面板(enabled:false),不白费模糊。
                // SafeArea:横屏时状态栏/刘海/挖孔常在顶部或左侧,否则首项(书架)会被遮。
                SafeArea(
                  right: false,
                  bottom: false,
                  child: GlassSurface(
                    enabled: false,
                    child: NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: _select,
                      labelType: NavigationRailLabelType.all,
                      groupAlignment: -0.85,
                      destinations: [
                        for (final d in _dests)
                          NavigationRailDestination(
                            icon: Icon(d.$1),
                            selectedIcon: Icon(d.$2),
                            label: Text(d.$3),
                          ),
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        // 窄屏:内容延伸到底栏之后(extendBody),毛玻璃才有内容可糊。
        return Scaffold(
          extendBody: true,
          body: body,
          bottomNavigationBar: GlassSurface(
            blur: 22,
            border: Border(top: BorderSide(color: p.line)),
            child: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _select,
              destinations: [
                for (final d in _dests)
                  NavigationDestination(
                    icon: Icon(d.$1),
                    selectedIcon: Icon(d.$2),
                    label: d.$3,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
