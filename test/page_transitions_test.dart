import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/app/theme/page_transitions.dart';
import 'package:dream_manga_reader/features/common/transitions.dart';
import 'package:dream_manga_reader/ui/app_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('app route owns an opaque background while sliding in and out',
      (tester) async {
    final host = await _pumpHost(tester);

    host.navigatorKey.currentState!.push(appRoute(
      const Scaffold(key: Key('second-page'), body: Text('second')),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.ancestor(
        of: find.byKey(const Key('second-page')),
        matching: find.byType(AppBackground),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('second-page'))).dx,
      greaterThan(0),
    );

    await tester.pumpAndSettle();
    host.navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester.getTopLeft(find.byKey(const Key('second-page'))).dx,
      greaterThan(0),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('material routes use the same isolated background',
      (tester) async {
    final host = await _pumpHost(tester);
    expect(
      Theme.of(host.context)
          .pageTransitionsTheme
          .builders
          .values
          .whereType<DreamPageTransitionsBuilder>(),
      hasLength(5),
    );

    host.navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) =>
          const Scaffold(key: Key('material-page'), body: Text('material')),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.ancestor(
        of: find.byKey(const Key('material-page')),
        matching: find.byType(AppBackground),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('disabled animations place app routes immediately',
      (tester) async {
    final host = await _pumpHost(tester);
    LibraryStore.animationsEnabled = false;

    host.navigatorKey.currentState!.push(appRoute(
      const Scaffold(key: Key('instant-page'), body: Text('instant')),
    ));
    await tester.pump();

    expect(
      tester.getTopLeft(find.byKey(const Key('instant-page'))).dx,
      0,
    );
    expect(
      find.ancestor(
        of: find.byKey(const Key('instant-page')),
        matching: find.byType(AppBackground),
      ),
      findsOneWidget,
    );
  });
}

Future<_TransitionHost> _pumpHost(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(const {});
  LibraryStore.animationsEnabled = true;
  final store = LibraryStore();
  await store.load();
  addTearDown(store.dispose);
  addTearDown(() => LibraryStore.animationsEnabled = true);
  final navigatorKey = GlobalKey<NavigatorState>();
  late BuildContext context;
  await tester.pumpWidget(LibraryScope(
    store: store,
    child: MaterialApp(
      navigatorKey: navigatorKey,
      theme: buildTheme(AppThemeVariant.dark),
      home: Builder(builder: (buildContext) {
        context = buildContext;
        return const Scaffold(
          key: Key('first-page'),
          body: Text('first'),
        );
      }),
    ),
  ));
  return _TransitionHost(navigatorKey, context);
}

class _TransitionHost {
  const _TransitionHost(this.navigatorKey, this.context);

  final GlobalKey<NavigatorState> navigatorKey;
  final BuildContext context;
}
