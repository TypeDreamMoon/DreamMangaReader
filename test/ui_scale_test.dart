// 桌面「界面缩放」是整块画布的等比缩放,文字的那一份由 FittedBox 带,不写进
// textScaler —— 两边都写就会乘两次。这几条用例把这个分工钉住:谁要是顺手往
// UiScale 的 MediaQuery 里补一个 textScaler,文字立刻变成 scale² 而其余不变,
// 这里会红。
import 'package:dream_manga_reader/features/common/ui_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _style = TextStyle(fontSize: 20, height: 1.0);

/// 这段文字最后在屏幕上占多高(已把 UiScale 的整体缩放算进去)。
double _onScreenHeight(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  ).height;
}

Future<double> _measure(
  WidgetTester tester, {
  required double uiScale,
  required double systemScale,
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = systemScale;
  await tester.pumpWidget(MaterialApp(
    home: const Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: Text('梦', style: _style),
      ),
    ),
    builder: (context, child) =>
        UiScale(scale: uiScale, child: child ?? const SizedBox.shrink()),
  ));
  return _onScreenHeight(tester, find.text('梦'));
}

void main() {
  testWidgets('界面缩放照样把文字放大', (tester) async {
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final base = await _measure(tester, uiScale: 1.0, systemScale: 1.0);
    final scaled = await _measure(tester, uiScale: 1.5, systemScale: 1.0);

    // FittedBox 是等比放大整块画布,文字不是例外。
    expect(scaled, closeTo(base * 1.5, 0.5));
  });

  testWidgets('界面缩放与系统字体放大各乘一次,不叠乘', (tester) async {
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final base = await _measure(tester, uiScale: 1.0, systemScale: 1.0);
    final system = await _measure(tester, uiScale: 1.0, systemScale: 1.3);
    final both = await _measure(tester, uiScale: 1.5, systemScale: 1.3);

    expect(system, closeTo(base * 1.3, 0.5));
    // 1.5 × 1.3,不是 1.5² × 1.3,也不是 1.5 × 1.3²。
    expect(both, closeTo(base * 1.5 * 1.3, 0.5));
    expect(both, isNot(closeTo(base * 1.5 * 1.5 * 1.3, 0.5)));
  });

  testWidgets('画布里报出来的 textScaler 只有系统那一份,缩放由画布本身带', (tester) async {
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;

    late TextScaler inner;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        inner = MediaQuery.textScalerOf(ctx);
        return const SizedBox.shrink();
      }),
      builder: (context, child) =>
          UiScale(scale: 1.5, child: child ?? const SizedBox.shrink()),
    ));

    // 界面缩放要是也写进 textScaler,文字就会被乘两次(一次 textScaler、一次 FittedBox)。
    expect(inner.scale(20), closeTo(26, 0.01));
  });

  testWidgets('Overlay 层(弹窗)和页面吃同一份界面缩放', (tester) async {
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.platformDispatcher.textScaleFactorTestValue = 1.0;

    await tester.pumpWidget(MaterialApp(
      home: const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Text('页面', style: _style),
        ),
      ),
      builder: (context, child) =>
          UiScale(scale: 1.5, child: child ?? const SizedBox.shrink()),
    ));

    final page = _onScreenHeight(tester, find.text('页面'));

    showDialog<void>(
      context: tester.element(find.text('页面')),
      builder: (_) => const AlertDialog(content: Text('弹窗', style: _style)),
    );
    await tester.pumpAndSettle();

    expect(_onScreenHeight(tester, find.text('弹窗')), closeTo(page, 0.5));
  });
}
