import 'package:flutter/material.dart';

import '../../app/app_info.dart';
import '../../app/theme/app_colors.dart';
import '../common/app_logo.dart';

/// 启动动画:朱印「梦」印章 + 应用名依次浮现,随后整层淡出露出 [child](其在身后已预热)。
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.child});

  final Widget child;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1750));
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    // 启动动画固定播放:不受「开启动画」开关影响(应用启动仪式感)。
    _ac.forward();
    _ac.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _hidden = true); // 动画完成后彻底移除遮罩
      }
    });
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Stack(
      children: [
        widget.child,
        if (!_hidden)
          AnimatedBuilder(
            animation: _ac,
            builder: (context, _) {
              final v = _ac.value;
              final seal =
                  const Interval(0.0, 0.42, curve: Curves.easeOutBack).transform(v);
              final name =
                  const Interval(0.30, 0.64, curve: Curves.easeOut).transform(v);
              final out =
                  const Interval(0.82, 1.0, curve: Curves.easeIn).transform(v);
              return IgnorePointer(
                ignoring: out > 0.5,
                child: Opacity(
                  opacity: (1 - out).clamp(0.0, 1.0),
                  // 用 Material(而非裸 Container)兜底:否则遮罩层文字继承 WidgetsApp 的
                // 兜底 DefaultTextStyle,出现黄色双下划线。
                child: Material(
                    color: p.background,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Opacity(
                            opacity: seal.clamp(0.0, 1.0),
                            child: Transform.scale(
                              scale: 0.72 + 0.28 * seal,
                              child: Transform.rotate(
                                  angle: -0.05 * (1 - seal),
                                  child: const AppLogo(size: 120, radius: 26)),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Opacity(
                            opacity: name.clamp(0.0, 1.0),
                            child: Transform.translate(
                              offset: Offset(0, 12 * (1 - name)),
                              child: Column(
                                children: [
                                  Text(AppInfo.name,
                                      style: TextStyle(
                                          color: p.textPrimary,
                                          fontSize: 20,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.5)),
                                  const SizedBox(height: 4),
                                  Text('${AppInfo.cnName} · 漫画阅读器',
                                      style: TextStyle(
                                          color: p.textMuted, fontSize: 12.5)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
