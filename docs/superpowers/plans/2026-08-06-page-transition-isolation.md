# Page Transition Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace transparent whole-page fades with background-isolated Apple-style navigation so page elements never visually overlap during transitions.

**Architecture:** Extract the existing global background into a reusable page surface, then route both custom `appRoute` and theme-driven `MaterialPageRoute` transitions through one horizontal transition builder. Keep root tabs in `IndexedStack`, immediately offstage the old tab, and animate only the newly selected tab content.

**Tech Stack:** Flutter, Dart, Material navigation, Widget tests

---

### Task 1: Extract a reusable opaque page background

**Files:**
- Move: `lib/features/common/app_background.dart` -> `lib/ui/app_background.dart`
- Modify: `lib/app/app.dart`
- Create: `test/app_background_test.dart`

- [ ] **Step 1: Write the failing background isolation test**

Create a widget test that hosts `AppBackground` under a real `LibraryScope` and theme. Give the foreground a transparent `Scaffold` and assert both the reusable backdrop and foreground exist:

```dart
testWidgets('app background keeps backdrop separate from foreground',
    (tester) async {
  SharedPreferences.setMockInitialValues(const {});
  final store = LibraryStore();
  await store.load();
  addTearDown(store.dispose);

  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(AppThemeVariant.dark),
    home: LibraryScope(
      store: store,
      child: const AppBackground(
        child: Scaffold(body: Text('foreground')),
      ),
    ),
  ));

  expect(find.byType(AppBackdrop), findsOneWidget);
  expect(find.text('foreground'), findsOneWidget);
  expect(
    find.descendant(
      of: find.byType(AppBackdrop),
      matching: find.byType(ColoredBox),
    ),
    findsWidgets,
  );
});
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
flutter test test\app_background_test.dart
```

Expected: compilation fails because `lib/ui/app_background.dart` and `AppBackdrop` do not exist.

- [ ] **Step 3: Move the background widget and split backdrop from foreground**

Move the existing file to `lib/ui/app_background.dart`. Keep all current image, blur, tint, `DetailTint`, animation-disable, and error fallback behavior in a public `AppBackdrop`:

```dart
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          const AppBackdrop(),
          child,
        ],
      );
}

class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    final p = context.palette;
    if (lib.bgImage.isEmpty) return ColoredBox(color: p.background);
    return ValueListenableBuilder<Color?>(
      valueListenable: DetailTint.color,
      builder: (context, detail, _) {
        var tint = p.background.withValues(alpha: lib.bgTintAlpha);
        if (detail != null) {
          tint = Color.lerp(
            tint,
            detail.withValues(alpha: lib.bgTintAlpha),
            lib.detailTintStrength,
          )!;
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: p.background),
            RepaintBoundary(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: lib.bgBlur,
                  sigmaY: lib.bgBlur,
                  tileMode: TileMode.decal,
                ),
                child: Image.file(
                  File(lib.bgImage),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
            TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: tint),
              duration: LibraryStore.animationsEnabled
                  ? const Duration(milliseconds: 450)
                  : Duration.zero,
              curve: Curves.easeOut,
              builder: (_, color, __) => ColoredBox(color: color ?? tint),
            ),
          ],
        );
      },
    );
  }
}
```

Update `lib/app/app.dart` to import `../ui/app_background.dart`. Delete the old path only after the new file is present; do not change the `MaterialApp.builder` ownership of the root background.

- [ ] **Step 4: Run GREEN and commit**

Run:

```powershell
flutter test test\app_background_test.dart test\widget_test.dart
dart analyze lib\ui\app_background.dart lib\app\app.dart test\app_background_test.dart
```

Expected: all tests pass and analysis reports no issues.

Commit:

```powershell
git add lib\features\common\app_background.dart lib\ui\app_background.dart lib\app\app.dart test\app_background_test.dart
git commit -m "refactor(ui): reuse the application backdrop per route"
```

### Task 2: Isolate hierarchical route transitions

**Files:**
- Create: `lib/app/theme/page_transitions.dart`
- Modify: `lib/app/theme/app_theme.dart`
- Modify: `lib/features/common/transitions.dart`
- Create: `test/page_transitions_test.dart`

- [ ] **Step 1: Write failing push and pop transition tests**

Build a small navigator with distinct keyed pages. Push through `appRoute`, stop at the middle frame, and assert the incoming page owns an `AppBackground` and is positioned to the right of the outgoing page. Then pop and assert its horizontal position increases before removal:

```dart
testWidgets('route owns an opaque background while sliding in and out',
    (tester) async {
  final navigatorKey = GlobalKey<NavigatorState>();
  SharedPreferences.setMockInitialValues(const {});
  final store = LibraryStore();
  await store.load();
  addTearDown(store.dispose);
  addTearDown(() => LibraryStore.animationsEnabled = true);
  await tester.pumpWidget(transitionTestApp(navigatorKey, store));

  navigatorKey.currentState!.push(appRoute(
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
  final pushX = tester.getTopLeft(find.byKey(const Key('second-page'))).dx;
  expect(pushX, greaterThan(0));

  await tester.pumpAndSettle();
  navigatorKey.currentState!.pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  final popX = tester.getTopLeft(find.byKey(const Key('second-page'))).dx;
  expect(popX, greaterThan(0));
});

Widget transitionTestApp(
  GlobalKey<NavigatorState> navigatorKey,
  LibraryStore store,
) =>
    LibraryScope(
      store: store,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: buildTheme(AppThemeVariant.dark),
        home: const Scaffold(
          key: Key('first-page'),
          body: Text('first'),
        ),
      ),
    );
```

Add a second test using `MaterialPageRoute` under `buildTheme` and assert it contains the same `DreamPageTransitionsBuilder` isolation surface. Add a disabled-animation test that sets `LibraryStore.animationsEnabled = false`, pushes with `appRoute`, pumps one frame, and expects the second page at `dx == 0`.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```powershell
flutter test test\page_transitions_test.dart
```

Expected: compilation fails because `DreamPageTransitionsBuilder` and the isolated transition function do not exist; the current `appRoute` also lacks `AppBackground`.

- [ ] **Step 3: Implement the shared Apple-style transition builder**

Create `lib/app/theme/page_transitions.dart` with one shared transition function and theme builder:

```dart
Widget buildDreamPageTransition({
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
}) {
  final surface = AppBackground(child: child);
  if (!LibraryStore.animationsEnabled) return surface;

  final incoming = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  final outgoing = CurvedAnimation(
    parent: secondaryAnimation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return SlideTransition(
    position: Tween(begin: const Offset(1, 0), end: Offset.zero)
        .animate(incoming),
    child: SlideTransition(
      position: Tween(begin: Offset.zero, end: const Offset(-0.08, 0))
          .animate(outgoing),
      child: surface,
    ),
  );
}

class DreamPageTransitionsBuilder extends PageTransitionsBuilder {
  const DreamPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      buildDreamPageTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      );
}
```

Set `DreamPageTransitionsBuilder` for Android, iOS, Windows, macOS, and Linux in `app_theme.dart`. Do not apply the builder to dialogs or bottom sheets.

- [ ] **Step 4: Make `appRoute` use the same transition**

Keep zero durations when animations are disabled. When enabled, use 240ms push and 220ms reverse durations and delegate its `transitionsBuilder` directly to `buildDreamPageTransition`. Remove the old page-wide fade and scale:

```dart
transitionsBuilder: (_, animation, secondaryAnimation, child) =>
    buildDreamPageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    ),
```

- [ ] **Step 5: Run GREEN and commit**

Run:

```powershell
flutter test test\page_transitions_test.dart test\theme_controller_test.dart test\widget_test.dart
dart analyze lib\app\theme\page_transitions.dart lib\app\theme\app_theme.dart lib\features\common\transitions.dart test\page_transitions_test.dart
```

Expected: push, pop, theme-route, and disabled-animation tests pass with no analysis issues.

Commit:

```powershell
git add lib\app\theme\page_transitions.dart lib\app\theme\app_theme.dart lib\features\common\transitions.dart test\page_transitions_test.dart
git commit -m "fix(ui): isolate hierarchical page transitions"
```

### Task 3: Keep root tab transitions single-page

**Files:**
- Modify: `lib/features/shell/home_shell.dart`
- Create: `test/home_shell_transition_test.dart`

- [ ] **Step 1: Write the failing tab midpoint test**

Pump the real app at a phone viewport, tap the discovery destination, and inspect the `IndexedStack` during the transition. Add stable keys around each tab child in `HomeShell` and assert only the selected tab is onstage while the controller is still animating:

```dart
testWidgets('tab switch offstages the old tab before animating the new tab',
    (tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(const App());
  await tester.pump();
  await tester.tap(find.text('发现').last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));

  expect(find.byKey(const Key('home-tab-0')), findsNothing);
  expect(find.byKey(const Key('home-tab-0'), skipOffstage: false), findsOneWidget);
  expect(find.byKey(const Key('home-tab-1')), findsOneWidget);
});
```

Add a state-retention assertion: switch back to tab 0 and confirm the original keyed subtree is reused rather than recreated.

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
flutter test test\home_shell_transition_test.dart
```

Expected: the test fails because stable tab keys are absent and the current 300ms whole-stack fade does not match the new contract.

- [ ] **Step 3: Animate only the selected tab content**

Keep `_built` and `IndexedStack`. Wrap each built page in a stable keyed boundary:

```dart
KeyedSubtree(
  key: ValueKey('home-tab-$i'),
  child: _pages[i],
)
```

Reduce the tab controller duration to 120ms. Keep `IndexedStack` responsible for offstaging the previous tab immediately. Move any opacity animation inside the selected stack result and start near full opacity (`0.88 -> 1`) so the global background never fades. Preserve `TabEntrance` for the active page only and preserve the zero-animation branch.

- [ ] **Step 4: Run GREEN and commit**

Run:

```powershell
flutter test test\home_shell_transition_test.dart test\widget_test.dart test\unified_library_page_test.dart
dart analyze lib\features\shell\home_shell.dart test\home_shell_transition_test.dart
```

Expected: old tab is offstage from the first switched frame, active tab state survives round trips, and all tests pass.

Commit:

```powershell
git add lib\features\shell\home_shell.dart test\home_shell_transition_test.dart
git commit -m "fix(ui): prevent root tab transition overlap"
```

### Task 4: Focused compatibility verification

**Files:**
- Modify: `docs/superpowers/plans/2026-08-06-page-transition-isolation.md`

- [ ] **Step 1: Run the focused navigation suite**

Run:

```powershell
flutter test test\app_background_test.dart test\page_transitions_test.dart test\home_shell_transition_test.dart test\widget_test.dart test\theme_controller_test.dart test\unified_library_page_test.dart test\anime_favorite_test.dart test\anime_history_resume_test.dart
```

Expected: all focused tests pass. Do not run the previously known hanging `anime_detail_download_test.dart` or `anime_downloads_view_test.dart`.

- [ ] **Step 2: Run focused formatting, analysis, and diff checks**

Run `dart format --output=none --set-exit-if-changed` and `dart analyze` on every Dart file touched by this plan, then:

```powershell
git diff --check
git status --short
```

Expected: formatting and analysis are clean; status contains only the plan completion update.

- [ ] **Step 3: Mark completed steps and commit the record**

Change completed plan checkboxes from `[ ]` to `[x]`, verify `git diff --check`, then commit:

```powershell
git add docs\superpowers\plans\2026-08-06-page-transition-isolation.md
git commit -m "docs(ui): record page transition verification"
```

## Deferred runtime validation

- Windows mouse-back and rapid navigation visual smoke test.
- Android system back, low-refresh-rate device, and custom-background visual smoke test.
- Real Hero cover animation and detail tint transition inspection.
- Windows/Android full builds, packaging, and device testing.
