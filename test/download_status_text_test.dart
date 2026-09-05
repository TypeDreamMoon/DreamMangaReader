import 'package:dream_manga_reader/app/download_coordinator_scope.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/downloads/download_coordinator.dart';
import 'package:dream_manga_reader/core/downloads/download_failure.dart';
import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:dream_manga_reader/core/l10n/app_strings.dart';
import 'package:dream_manga_reader/features/downloads/downloads_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

Future<DownloadCoordinator> _coordinatorWith(
  List<DownloadTask> tasks,
  WidgetTester tester,
) async {
  final repository = RecordingDownloadTaskRepository()..loaded = tasks;
  final coordinator = DownloadCoordinator(
    repository: repository,
    environment: () async => unrestrictedEnvironment,
    settings: DownloadPolicySettings.new,
  );
  await coordinator.load();
  addTearDown(coordinator.dispose);
  return coordinator;
}

Future<void> _pumpDownloads(
  WidgetTester tester,
  DownloadCoordinator coordinator, {
  Locale locale = const Locale('zh'),
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(AppThemeVariant.light),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: DownloadCoordinatorScope(
      coordinator: coordinator,
      child: const DownloadsPage(),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('failed tasks read their text from the failure code',
      (tester) async {
    final coordinator = await _coordinatorWith([
      taskFixture(state: DownloadTaskState.failed).copyWith(
        failure: DownloadFailure.fromDetail(
          DownloadFailureCode.insufficientStorage,
          'FileSystemException: No space left on device',
        ),
      ),
    ], tester);

    await _pumpDownloads(tester, coordinator);

    expect(find.text('存储空间不足'), findsOneWidget);
    // 详情默认收起。
    expect(find.textContaining('No space left'), findsNothing);

    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('No space left on device'), findsOneWidget);
  });

  testWidgets('failure text follows the reader locale', (tester) async {
    final coordinator = await _coordinatorWith([
      taskFixture(state: DownloadTaskState.failed).copyWith(
        failure: DownloadFailure.fromDetail(
          DownloadFailureCode.authenticationRequired,
          'HttpException: 401',
        ),
      ),
    ], tester);

    await _pumpDownloads(tester, coordinator, locale: const Locale('en'));

    expect(find.text('Sign in again to continue'), findsOneWidget);
  });

  testWidgets('a failure without a detail shows no expander', (tester) async {
    final coordinator = await _coordinatorWith([
      taskFixture(state: DownloadTaskState.failed).copyWith(
        failure: DownloadFailure.fromDetail(DownloadFailureCode.unknown, ''),
      ),
    ], tester);

    await _pumpDownloads(tester, coordinator);

    expect(find.text('下载失败'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
  });
}
