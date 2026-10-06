import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/ui/smooth_scroll.dart';

/// 外层 SmoothScroll(视口 600)里放一个高 200、内容 1200 的里层列表:
/// 外层滚不动,里层能滚。
Widget _nested({
  required ScrollController inner,
  required double outerChildHeight,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 600,
        child: SmoothScroll(
          builder: (c) => ListView(
            controller: c,
            children: [
              SizedBox(
                height: 200,
                child: ListView(
                  controller: inner,
                  children: [
                    for (var i = 0; i < 20; i++)
                      SizedBox(height: 60, child: Text('inner $i')),
                  ],
                ),
              ),
              SizedBox(height: outerChildHeight),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _wheel(WidgetTester tester, Offset at, double dy) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  pointer.hover(at);
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  setUp(() => LibraryStore.scrollAnimationsEnabled = true);

  testWidgets('an outer list that cannot scroll leaves the wheel to the inner',
      (WidgetTester tester) async {
    // 这就是回归点:盖层过去无条件向 resolver 抢注,回调里才发现
    // maxScrollExtent == 0 直接返回 —— resolver 只认第一个注册者,里层永远收不到,
    // 这一格滚轮凭空消失。
    final inner = ScrollController();
    addTearDown(inner.dispose);
    await tester.pumpWidget(_nested(inner: inner, outerChildHeight: 0));

    await _wheel(tester, tester.getCenter(find.text('inner 0')), 120);

    expect(inner.offset, greaterThan(0));
  });

  testWidgets('a scrollable outer list still takes the wheel over',
      (WidgetTester tester) async {
    final inner = ScrollController();
    addTearDown(inner.dispose);
    // 外层多塞 2000 高 → 外层可滚,平滑滚动照常接管。
    await tester.pumpWidget(_nested(inner: inner, outerChildHeight: 2000));

    final outer = tester
        .widget<ListView>(find.byType(ListView).first)
        .controller!;
    await _wheel(tester, tester.getCenter(find.text('inner 0')), 120);
    // animateTo 需要时间推进。
    await tester.pump(const Duration(milliseconds: 400));

    expect(outer.offset, greaterThan(0));
    expect(inner.offset, 0);
  });

  testWidgets('the wheel is left alone when scroll animations are off',
      (WidgetTester tester) async {
    LibraryStore.scrollAnimationsEnabled = false;
    addTearDown(() => LibraryStore.scrollAnimationsEnabled = true);
    final inner = ScrollController();
    addTearDown(inner.dispose);
    await tester.pumpWidget(_nested(inner: inner, outerChildHeight: 2000));

    final outer = tester
        .widget<ListView>(find.byType(ListView).first)
        .controller!;
    await _wheel(tester, tester.getCenter(find.text('inner 0')), 120);
    await tester.pump(const Duration(milliseconds: 400));

    // 关掉动画后不接管:系统默认滚轮把事件交给命中的里层。
    expect(outer.offset, 0);
    expect(inner.offset, greaterThan(0));
  });
}
