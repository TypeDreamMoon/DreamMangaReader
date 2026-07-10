import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app/library_store.dart';

/// 桌面鼠标滚轮**平滑滚动**:把一格一跳的滚轮改成动画滚到目标位。
///
/// 用法:`SmoothScroll(builder: (c) => ListView(controller: c, ...))`——本控件持有
/// [ScrollController] 交给 builder 里的可滚组件,并在其上盖一层只处理滚轮信号的
/// 透明层,用 `pointerSignalResolver` **抢先**接管滚轮(盖层在栈顶=命中最先注册=胜出),
/// 从而避开默认跳变;点击/拖动/悬停照常透传到下面的列表。
///
/// 触摸/触控板本就连续顺滑;此层只对「离散滚轮」有意义。受「滚动动画」设置控制,
/// 关掉时不接管(退回系统默认滚轮)。
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({
    super.key,
    required this.builder,
    this.controller,
    this.duration = const Duration(milliseconds: 220),
    this.curve = Curves.easeOutCubic,
  });

  // ---- 滚轮让位(横向条用)----
  // 指针悬停在 AppHStrip 之类「滚轮转横滑」的区域时置位:盖层不抢注滚轮,
  // 让横条自己经 resolver 接管(否则盖层在栈顶必胜,横条永远收不到)。
  static int _yield = 0;
  static void pushYield() => _yield++;
  static void popYield() => _yield = _yield > 0 ? _yield - 1 : 0;
  static bool get _yielding => _yield > 0;

  /// 用传入的 controller 构建可滚组件(务必把它设到 controller: 上)。
  final Widget Function(ScrollController controller) builder;

  /// 外部控制器(如无限滚动 / 位置监听的页面自带)。为空则内部自建并负责释放。
  final ScrollController? controller;
  final Duration duration;
  final Curve curve;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  ScrollController? _own; // 仅当没传外部 controller 时自建
  ScrollController get _c => widget.controller ?? _own!;
  double? _target;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _own = ScrollController();
  }

  @override
  void didUpdateWidget(SmoothScroll old) {
    super.didUpdateWidget(old);
    // 外部 controller 的有无发生切换:相应地建/释放自建控制器。
    if (widget.controller == null && _own == null) {
      _own = ScrollController();
    } else if (widget.controller != null && _own != null) {
      _own!.dispose();
      _own = null;
    }
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (SmoothScroll._yielding) return; // 指针在横向条上:滚轮让给它
    if (!LibraryStore.scrollAnimationsEnabled) return;
    if (!_c.hasClients) return;
    // 用 resolver 注册:盖层在栈顶最先派发 → 最先注册 → resolver 只调用我们,
    // 系统默认滚轮被跳过(不会双重滚动)。
    GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
      _handle(ev as PointerScrollEvent);
    });
  }

  void _handle(PointerScrollEvent e) {
    if (!_c.hasClients) return;
    final pos = _c.position;
    final max = pos.maxScrollExtent;
    if (max <= 0) return; // 不可滚,交给里层(横向等)自行处理
    // 基准位置:若上次目标已漂移(用户拖过/惯性/越界),回到实际像素。
    var base = _target ?? pos.pixels;
    if ((base - pos.pixels).abs() > pos.viewportDimension) base = pos.pixels;
    final t = (base + e.scrollDelta.dy).clamp(0.0, max);
    _target = t;
    if ((t - pos.pixels).abs() < 0.5) return;
    _c.animateTo(t, duration: widget.duration, curve: widget.curve);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.builder(_c),
        // 只接管滚轮信号的透明盖层;translucent → 点击/拖动/悬停透传到下面列表。
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: _onSignal,
          ),
        ),
      ],
    );
  }
}
