import 'package:dream_manga_reader/features/common/transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 连点保护。
///
/// 真实成因是**点击到推页面之间那段异步**:不少入口先取数据再开页
/// (「继续观看」要先把分集列表拉回来),这段时间页面完全可点,点两下就起了两条
/// 并发链路,各自推一层一模一样的页面。取数据越慢越容易中 —— 也就是「有时候」。
class _Detail extends StatelessWidget {
  const _Detail();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('detail')));
}

/// 模拟「点了之后先取数据,再开页」。
Widget _app({required bool guarded}) => MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                await Future<void>.delayed(const Duration(milliseconds: 100));
                if (!context.mounted) return;
                if (guarded) {
                  await pushPage(context, const _Detail());
                } else {
                  await Navigator.of(context).push(appRoute(const _Detail()));
                }
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

int _detailCount(WidgetTester tester) =>
    tester.widgetList(find.byType(_Detail, skipOffstage: false)).length;

Future<void> _doubleTap(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 30));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  // 先证明坑是真的,否则「修好了」无从谈起。
  testWidgets('没有保护:取数据期间点两下,叠出两层', (tester) async {
    await tester.pumpWidget(_app(guarded: false));
    await _doubleTap(tester);

    expect(_detailCount(tester), 2);
  });

  testWidgets('pushPage 只放行第一下', (tester) async {
    await tester.pumpWidget(_app(guarded: true));
    await _doubleTap(tester);

    expect(_detailCount(tester), 1);
  });

  // 判据是「调用方还在不在最顶上」,不是时间窗 —— 所以返回后立刻再开不该被误伤。
  // 用时间窗做这件事,这条就会挂。
  testWidgets('返回之后立刻再开,照常推得动', (tester) async {
    await tester.pumpWidget(_app(guarded: true));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(_detailCount(tester), 1);

    Navigator.of(tester.element(find.byType(_Detail))).pop();
    await tester.pumpAndSettle();
    expect(_detailCount(tester), 0);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(_detailCount(tester), 1);
  });
}
