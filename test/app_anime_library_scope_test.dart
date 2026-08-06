import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/app.dart';
import 'package:dream_manga_reader/core/downloads/download_coordinator.dart';
import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/download_fixtures.dart';

void main() {
  testWidgets('app loads and exposes anime library state', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final coordinator = DownloadCoordinator(
      repository: RecordingDownloadTaskRepository(),
      environment: () async => unrestrictedEnvironment,
      settings: DownloadPolicySettings.new,
    );

    await tester.pumpWidget(App(downloadCoordinator: coordinator));

    expect(find.byType(AnimeLibraryScope), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    coordinator.dispose();
  });
}
