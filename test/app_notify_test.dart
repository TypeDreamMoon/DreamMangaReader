import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/ui/app_notify.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _themed(Widget child) => MediaQuery(
      data: const MediaQueryData(size: Size(600, 800)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(data: buildTheme(AppThemeVariant.dark), child: child),
      ),
    );

/// 一个独立的 Overlay(带 key,换树时不会被复用),并把它内部的 context 交出来。
Widget _overlay(String tag, void Function(BuildContext) capture) => Overlay(
      key: ValueKey<String>(tag),
      initialEntries: <OverlayEntry>[
        OverlayEntry(builder: (ctx) {
          capture(ctx);
          return const SizedBox.expand();
        }),
      ],
    );

void main() {
  testWidgets('一个 Overlay 里弹通知,不会撤掉另一个 Overlay 里正显示的那条',
      (tester) async {
    late BuildContext top;
    late BuildContext bottom;
    await tester.pumpWidget(_themed(Column(
      children: <Widget>[
        Expanded(child: _overlay('top', (c) => top = c)),
        Expanded(child: _overlay('bottom', (c) => bottom = c)),
      ],
    )));

    showAppNotify(top, 'alpha');
    await tester.pump();
    showAppNotify(bottom, 'beta');
    await tester.pump();

    // 「同一时刻只保留一个」是每个 Overlay 各自的事,不是全进程一条。
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);

    // 各自到点各自收:两条都走完自己的超时与收起动画。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('alpha'), findsNothing);
    expect(find.text('beta'), findsNothing);
  });

  testWidgets('同一个 Overlay 里,新通知顶替旧的而不是叠加', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(_themed(_overlay('only', (c) => ctx = c)));

    showAppNotify(ctx, 'first');
    await tester.pump();
    showAppNotify(ctx, 'second');
    await tester.pump();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
  });

  testWidgets('旧树连同它的通知一起销毁后,新树照样弹得出来', (tester) async {
    late BuildContext first;
    await tester.pumpWidget(_themed(_overlay('old', (c) => first = c)));
    showAppNotify(first, 'gone');
    await tester.pump();
    expect(find.text('gone'), findsOneWidget);

    // 整棵树换掉:旧 Overlay 没了,那条通知的 entry 也不该再被人惦记着去 remove。
    late BuildContext second;
    await tester.pumpWidget(_themed(_overlay('new', (c) => second = c)));
    expect(find.text('gone'), findsNothing);

    showAppNotify(second, 'fresh');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('fresh'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('fresh'), findsNothing);
  });
}
