import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/ui/app_underline_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(String selected, ValueChanged<String> onSelected) => MaterialApp(
        theme: buildTheme(AppThemeVariant.light),
        home: Scaffold(
          body: AppUnderlineTabs<String>(
            selected: selected,
            onSelected: onSelected,
            tabs: const [
              AppUnderlineTab(
                  value: 'all',
                  label: '全部',
                  count: 14,
                  tabKey: ValueKey('tab-all')),
              AppUnderlineTab(
                  value: 'manga', label: '漫画', tabKey: ValueKey('tab-manga')),
            ],
          ),
        ),
      );

  testWidgets('reports the tapped tab and renders its count', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(host('all', tapped.add));
    await tester.pumpAndSettle();

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('14'), findsOneWidget); // 计数只在有值时出现
    expect(find.text('0'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tab-manga')));
    expect(tapped, ['manga']);
  });

  testWidgets('re-tapping the selected tab still reports it', (tester) async {
    // 去重交给调用方(书架/发现页都在 onSelected 里早退),组件本身不吞事件。
    final tapped = <String>[];
    await tester.pumpWidget(host('all', tapped.add));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tab-all')));
    expect(tapped, ['all']);
  });

  testWidgets('the indicator sits only under the selected tab', (tester) async {
    await tester.pumpWidget(host('manga', (_) {}));
    await tester.pumpAndSettle();

    // 两个 tab 各有一条下划线,未选中那条被缩到 0 宽 + 全透明。
    final opacities = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .map((o) => o.opacity)
        .toList()
      ..sort();
    expect(opacities, [0.0, 1.0]);
  });
}
