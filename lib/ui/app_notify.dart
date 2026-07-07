import 'dart:async';

import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import 'glass.dart';

/// 通知语气:决定默认图标与强调色。
enum AppNotifyKind { info, success, warn, error }

/// 顶部毛玻璃通知(替代底部 SnackBar)。
///
/// - 挂在 Navigator 的 Overlay 顶层 → 浮在页面 / 底部弹层之上,从顶部滑入。
/// - 背景走 [GlassSurface](身后页面被模糊),圆角跟随全局 `context.radius`。
/// - 填充色按主题自动推导(Dark/OLED 深玻璃、Light 亮玻璃),点按可提前关闭。
/// - 同一时刻只保留一个:再次调用会替换掉上一个(常用于「检查中… → 结果」)。
void showAppNotify(
  BuildContext context,
  String message, {
  IconData? icon,
  AppNotifyKind kind = AppNotifyKind.info,
  Duration duration = const Duration(milliseconds: 2200),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  // 先关掉上一个(幂等,安全):新通知立刻顶替,不叠加。
  _active?.remove();

  final handle = _NotifyHandle();
  handle.entry = OverlayEntry(
    builder: (ctx) => _AppNotifyHost(
      message: message,
      icon: icon,
      kind: kind,
      duration: duration,
      onGone: handle.remove,
    ),
  );
  _active = handle;
  overlay.insert(handle.entry!);
}

_NotifyHandle? _active;

/// 单个通知的移除句柄:把「移除」做成幂等,避免动画收尾与被顶替时重复 remove。
class _NotifyHandle {
  OverlayEntry? entry;
  bool _removed = false;
  void remove() {
    if (_removed) return;
    _removed = true;
    entry?.remove();
    entry = null;
    if (identical(_active, this)) _active = null;
  }
}

class _AppNotifyHost extends StatefulWidget {
  const _AppNotifyHost({
    required this.message,
    required this.icon,
    required this.kind,
    required this.duration,
    required this.onGone,
  });

  final String message;
  final IconData? icon;
  final AppNotifyKind kind;
  final Duration duration;
  final VoidCallback onGone;

  @override
  State<_AppNotifyHost> createState() => _AppNotifyHostState();
}

class _AppNotifyHostState extends State<_AppNotifyHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260));
  Timer? _hide;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _ac.forward();
    _hide = Timer(widget.duration, _dismiss);
  }

  void _dismiss() {
    if (_dismissing) return;
    _dismissing = true;
    _hide?.cancel();
    _ac.reverse().whenComplete(widget.onGone);
  }

  @override
  void dispose() {
    _hide?.cancel();
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final topInset = MediaQuery.of(context).viewPadding.top;

    final Color tone = switch (widget.kind) {
      AppNotifyKind.info => p.accent,
      AppNotifyKind.success => p.accent,
      AppNotifyKind.warn => p.downloaded,
      AppNotifyKind.error => const Color(0xFFE5565B),
    };
    final IconData ic = widget.icon ??
        switch (widget.kind) {
          AppNotifyKind.info => Icons.info_rounded,
          AppNotifyKind.success => Icons.check_circle_rounded,
          AppNotifyKind.warn => Icons.warning_rounded,
          AppNotifyKind.error => Icons.error_rounded,
        };

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: _dismissing,
        child: Padding(
          padding: EdgeInsets.only(top: topInset + 10, left: 16, right: 16),
          child: Align(
            alignment: Alignment.topCenter,
            child: AnimatedBuilder(
              animation: _ac,
              builder: (_, child) {
                final v = Curves.easeOutCubic.transform(_ac.value);
                return Opacity(
                  opacity: v.clamp(0.0, 1.0),
                  child: Transform.translate(
                      offset: Offset(0, (1 - v) * -18), child: child),
                );
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                // 裸 Overlay 无 Material 祖先 → 兜底一层,否则文字继承 WidgetsApp
                // 的 DefaultTextStyle 出现黄色双下划线。
                child: Material(
                  type: MaterialType.transparency,
                  child: GestureDetector(
                    onTap: _dismiss,
                    child: GlassSurface(
                      borderRadius: BorderRadius.circular(context.radius),
                      blur: 24,
                      border: Border.all(color: p.line),
                      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(ic, size: 18, color: tone),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              widget.message,
                              style: TextStyle(
                                  color: p.textPrimary,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  height: 1.3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
