import 'package:dream_manga_reader/app/download_coordinator_scope.dart';
import 'package:dream_manga_reader/core/downloads/download_coordinator.dart';
import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

void main() {
  late RecordingDownloadTaskRepository repository;
  late DownloadCoordinator coordinator;

  setUp(() {
    repository = RecordingDownloadTaskRepository();
    coordinator = DownloadCoordinator(
      repository: repository,
      environment: () async => unrestrictedEnvironment,
      settings: DownloadPolicySettings.new,
    );
  });

  tearDown(() => coordinator.dispose());

  testWidgets('read exposes the shared coordinator without subscribing',
      (tester) async {
    var builds = 0;
    late DownloadCoordinator observed;
    await tester.pumpWidget(
      DownloadCoordinatorScope(
        coordinator: coordinator,
        child: MaterialApp(
          home: Builder(builder: (context) {
            builds++;
            observed = DownloadCoordinatorScope.read(context);
            return const SizedBox();
          }),
        ),
      ),
    );

    await tester.runAsync(coordinator.load);
    await tester.pump();

    expect(observed, same(coordinator));
    expect(builds, 1);
  });

  testWidgets('of subscribes descendants to coordinator changes',
      (tester) async {
    var builds = 0;
    await tester.pumpWidget(
      DownloadCoordinatorScope(
        coordinator: coordinator,
        child: MaterialApp(
          home: Builder(builder: (context) {
            builds++;
            DownloadCoordinatorScope.of(context);
            return const SizedBox();
          }),
        ),
      ),
    );

    await tester.runAsync(coordinator.load);
    await tester.pump();

    expect(builds, 2);
  });

  testWidgets('missing scope produces a clear assertion', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (value) {
          context = value;
          return const SizedBox();
        }),
      ),
    );

    expect(
      () => DownloadCoordinatorScope.read(context),
      throwsA(isA<AssertionError>()),
    );
    expect(DownloadCoordinatorScope.maybeRead(context), isNull);
    expect(DownloadCoordinatorScope.maybeOf(context), isNull);
  });
}
