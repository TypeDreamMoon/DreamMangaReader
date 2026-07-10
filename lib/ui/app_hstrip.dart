import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_scroll_view.dart';
import 'smooth_scroll.dart';

/// 桌面友好的**横向**滚动条容器(书架「继续阅读」「为你推荐」、详情页「相关推荐」共用):
/// - 竖向滚轮转横向滚动(桌面鼠标没有横滚轮,否则溢出屏外的卡片够不着);
/// - 允许鼠标/触控板拖拽(Flutter 默认桌面鼠标拖不动列表);
/// - 隐藏横向滚动条(矮条上滚动条会压住内容)。
class AppHStrip extends StatefulWidget {
  const AppHStrip.separated({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.separatorBuilder,
    this.controller,
    this.padding,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder separatorBuilder;

  /// 外部要保留/监听滚动位置时传入;不传则内部自建自管。
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;

  @override
  State<AppHStrip> createState() => _AppHStripState();
}

class _AppHStripState extends State<AppHStrip> {
  ScrollController? _own;
  ScrollController get _ctrl =>
      widget.controller ?? (_own ??= ScrollController());
  bool _hovering = false;

  @override
  void dispose() {
    // 悬停中被移出树(切页等):onExit 不会再来,手动归还让位计数。
    if (_hovering) SmoothScroll.popYield();
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // 悬停时让 SmoothScroll 的滚轮盖层让位,否则它在栈顶必胜、横条收不到滚轮。
      onEnter: (_) {
        if (!_hovering) {
          _hovering = true;
          SmoothScroll.pushYield();
        }
      },
      onExit: (_) {
        if (_hovering) {
          _hovering = false;
          SmoothScroll.popYield();
        }
      },
      child: Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && _ctrl.hasClients) {
            // 经 resolver 仲裁:本层在外层 Scrollable 之前派发 → 先注册者胜,
            // 页面不会跟着竖滚(否则滚轮一动横条和页面一起走,斜着跑)。
            GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
              if (!_ctrl.hasClients) return;
              final s = (ev as PointerScrollEvent).scrollDelta;
              final d = s.dy != 0 ? s.dy : s.dx;
              _ctrl.jumpTo((_ctrl.offset + d)
                  .clamp(0.0, _ctrl.position.maxScrollExtent));
            });
          }
        },
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: const {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            },
            scrollbars: false,
          ),
          child: AppScrollView.separated(
            controller: _ctrl,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: widget.itemCount,
            itemBuilder: widget.itemBuilder,
            separatorBuilder: widget.separatorBuilder,
          ),
        ),
      ),
    );
  }
}
