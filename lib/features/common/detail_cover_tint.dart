import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/ui_signals.dart';
import '../../core/color/cover_palette.dart';

/// 详情页的「封面主色」生命周期:取色 → 推给全局背景 → 离场出栈 → 取消返回再压回。
///
/// 漫画/番剧/小说三个详情页原本各抄了一份(6 个字段 + initState/dispose/
/// didChangeDependencies/路由监听/取色 五处),逐字相同。收成 mixin 后
/// 页面只需在拿到封面 url 时调一次 [updateCoverTint],其余全自动。
///
/// 用法:`class _XState extends State<X> with DetailCoverTint<X> { ... }`,
/// 页面自己的 initState/dispose/didChangeDependencies 记得照常调 super。
mixin DetailCoverTint<T extends StatefulWidget> on State<T> {
  CoverPalette? _cover;
  String? _paletteFor; // 已算过取色的封面 url(同一张不重复算)
  late Object _tintToken; // 全局背景封面色的栈 token(本页在栈,离开出栈)
  Color? _coverTint; // 算好的封面色(取消返回手势时用它重新压栈)
  bool _tintPushed = true; // 封面色当前是否在栈里
  ModalRoute<dynamic>? _route;

  /// 封面主色板;null = 没封面 / 还没算好 / 取色失败。
  CoverPalette? get coverPalette => _cover;

  /// 页面强调色:封面主色 > 主题 accent。
  Color get coverAccent => _cover?.primary ?? context.palette.accent;

  @override
  void initState() {
    super.initState();
    _tintToken = DetailTint.push(); // 进入详情:入栈(取色算好后 update)
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.animation?.removeStatusListener(_onRouteAnim);
      _route = route;
      _route?.animation?.addStatusListener(_onRouteAnim);
    }
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteAnim);
    if (_tintPushed) DetailTint.pop(_tintToken); // 兜底:还在栈里就出栈
    super.dispose();
  }

  /// 返回一开始就把封面色出栈,背景在离场动画里就渐变回设置色;
  /// 取消返回手势(动画倒回)则重新压栈。
  void _onRouteAnim(AnimationStatus status) {
    final leaving = status == AnimationStatus.reverse ||
        status == AnimationStatus.dismissed;
    if (leaving && _tintPushed) {
      _tintPushed = false;
      DetailTint.pop(_tintToken);
    } else if (!leaving && !_tintPushed && mounted) {
      _tintPushed = true;
      _tintToken = DetailTint.push(_coverTint);
    }
  }

  /// 丢弃已算出的封面色(换源 = 换封面,旧主题色不能留着)。
  /// 调用方通常紧接着用新封面再调一次 [updateCoverTint]。
  void resetCoverTint() {
    _cover = null;
    _paletteFor = null;
  }

  /// 从封面图算主题色并推给全局背景。同一张 url 只算一次;算的过程中封面换了
  /// (换源/补详情)则丢弃这次结果。取不到色(如小说的生成式封面)保持主题 accent。
  Future<void> updateCoverTint(String? url,
      [Map<String, String> headers = const {}]) async {
    if (url == null || url.isEmpty || url == _paletteFor) return;
    _paletteFor = url;
    final palette = await extractCoverPalette(url, headers);
    if (!mounted || palette == null || _paletteFor != url) return;
    setState(() => _cover = palette);
    _coverTint = palette.primary;
    if (_tintPushed) DetailTint.update(_tintToken, palette.primary);
  }
}
