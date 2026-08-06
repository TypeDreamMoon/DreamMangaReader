import 'package:dream_manga_reader/app/app.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('tab switch offstages the old tab before animating the new tab',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    LibraryStore.animationsEnabled = true;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => LibraryStore.animationsEnabled = true);

    await tester.pumpWidget(const App());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1800));
    final originalLibrary = tester.element(find.byKey(const Key('home-tab-0')));

    await tester.tap(find.text('发现').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.byKey(const Key('home-tab-0')), findsNothing);
    expect(
      find.byKey(const Key('home-tab-0'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const Key('home-tab-1')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 70));
    final transition = tester.widget<FadeTransition>(
      find.byKey(const Key('home-tab-transition')),
    );
    expect(transition.opacity.value, 1);

    await tester.tap(find.text('书架').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    expect(
      tester.element(find.byKey(const Key('home-tab-0'))),
      same(originalLibrary),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
