// Smoke test:确认 App 启动到底部导航外壳(书架)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/app/app.dart';

void main() {
  testWidgets('App boots to the library shell', (WidgetTester tester) async {
    // 用手机竖屏尺寸,让响应式外壳走底部 NavigationBar(宽屏 >=640 会换成左侧 Rail)。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const App());
    await tester.pump();

    // 底部导航 + 书架标题/标签。
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('书架'), findsWidgets);

    // 拆掉 App(触发 dispose,取消启动更新计时器),避免遗留待触发 Timer 让测试失败。
    await tester.pumpWidget(const SizedBox());
  });
}
