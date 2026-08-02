import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:dream_manga_reader/core/update/update_downloader.dart';
import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:dream_manga_reader/core/update/update_resolver.dart';
import 'package:dream_manga_reader/core/update/update_service.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _sha256 =
    '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';

UpdateCandidate _candidate({
  UpdateSource source = UpdateSource.gitee,
  bool compatible = true,
  List<UpdateCandidate> alternates = const [],
}) {
  const fileName = 'DreamMangaReader-windows-x64-setup.exe';
  final manifest = UpdateManifest(
    schemaVersion: 1,
    appId: 'DreamMangaReader',
    version: '1.3.1',
    channel: 'stable',
    assets: [
      ManifestAsset(
        platform: UpdatePlatform.windows,
        arch: compatible ? 'x64' : 'arm64',
        kind: 'installer',
        fileName: fileName,
        sha256: _sha256,
        sizeBytes: 3,
      ),
    ],
  );
  return UpdateCandidate(
    source: source,
    version: '1.3.1',
    tag: 'v1.3.1',
    pageUrl: 'https://example/release',
    notes: 'notes',
    prerelease: false,
    assets: const [
      RemoteAsset(
        name: fileName,
        url: 'https://example/setup.exe',
        size: 3,
      ),
    ],
    integrity: UpdateIntegrity.manifest,
    manifest: manifest,
    alternates: alternates,
  );
}

Future<void> _openDialog(
  WidgetTester tester,
  UpdateCandidate candidate,
  UpdateDialogDependencies dependencies,
) async {
  late BuildContext hostContext;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      theme: ThemeData.dark().copyWith(
        extensions: const [AppTokens(palette: AppPalette.oled)],
      ),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(
        builder: (context) {
          hostContext = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  unawaited(
    showUpdateDialog(
      hostContext,
      candidate,
      dependencies: dependencies,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory temp;
  late File package;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dmr-update-dialog-test-');
    package = File('${temp.path}${Platform.pathSeparator}setup.exe')
      ..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  testWidgets('shows Gitee source and starts in-app download', (tester) async {
    var downloads = 0;
    var installs = 0;
    var manualOpens = 0;
    final installGate = Completer<void>();
    await _openDialog(
      tester,
      _candidate(),
      UpdateDialogDependencies(
        download: (asset, {required cancelToken, required onProgress}) async {
          downloads++;
          onProgress(1);
          return package;
        },
        install: (file, {onBeforeExit}) {
          installs++;
          return installGate.future;
        },
        openManual: (_) async => manualOpens++,
      ),
    );

    expect(find.text('Gitee'), findsOneWidget);
    await tester.tap(find.byKey(const Key('update-primary')));
    await tester.pump();

    expect(downloads, 1);
    expect(installs, 1);
    expect(manualOpens, 0);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, 1);

    installGate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('shows GitHub as the fallback source', (tester) async {
    await _openDialog(
      tester,
      _candidate(source: UpdateSource.github),
      UpdateDialogDependencies(
        download: (asset, {required cancelToken, required onProgress}) async =>
            package,
        install: (file, {onBeforeExit}) async {},
        openManual: (_) async {},
      ),
    );

    expect(find.text('GitHub / 备用源'), findsOneWidget);
  });

  testWidgets('cancel button cancels the active download token',
      (tester) async {
    CancelToken? observedToken;
    await _openDialog(
      tester,
      _candidate(),
      UpdateDialogDependencies(
        download: (asset, {required cancelToken, required onProgress}) {
          observedToken = cancelToken;
          return cancelToken.whenCancel.then<File>((error) => throw error);
        },
        install: (file, {onBeforeExit}) async {},
        openManual: (_) async {},
      ),
    );

    await tester.tap(find.byKey(const Key('update-primary')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('update-cancel')));
    await tester.pumpAndSettle();

    expect(observedToken?.isCancelled, isTrue);
    expect(find.byKey(const Key('update-primary')), findsOneWidget);
  });

  testWidgets('cancel during verification never launches the installer',
      (tester) async {
    final downloadGate = Completer<File>();
    var installs = 0;
    await _openDialog(
      tester,
      _candidate(),
      UpdateDialogDependencies(
        download: (asset, {required cancelToken, required onProgress}) {
          onProgress(1);
          return downloadGate.future;
        },
        install: (file, {onBeforeExit}) async => installs++,
        openManual: (_) async {},
      ),
    );

    await tester.tap(find.byKey(const Key('update-primary')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('update-cancel')));
    downloadGate.complete(package);
    await tester.pumpAndSettle();

    expect(installs, 0);
    expect(find.byKey(const Key('update-primary')), findsOneWidget);
  });

  testWidgets('integrity failure offers retry and manual download',
      (tester) async {
    await _openDialog(
      tester,
      _candidate(),
      UpdateDialogDependencies(
        download: (asset, {required cancelToken, required onProgress}) =>
            throw const UpdateIntegrityException('bad hash'),
        install: (file, {onBeforeExit}) async {},
        openManual: (_) async {},
      ),
    );

    await tester.tap(find.byKey(const Key('update-primary')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('update-retry')), findsOneWidget);
    expect(find.byKey(const Key('update-manual')), findsOneWidget);
  });

  testWidgets('switches to the alternate source when the preferred one has no '
      'compatible asset', (tester) async {
    var downloads = 0;
    await _openDialog(
      tester,
      _candidate(
        compatible: false,
        alternates: [_candidate(source: UpdateSource.github)],
      ),
      UpdateDialogDependencies(
        download: (asset, {required cancelToken, required onProgress}) async {
          downloads++;
          onProgress(1);
          return package;
        },
        install: (file, {onBeforeExit}) async {},
        openManual: (_) async {},
      ),
    );

    // 换源后标题、说明和下载页都要跟着走,不能只换下载地址。
    expect(find.text('GitHub / 备用源'), findsOneWidget);
    expect(find.byKey(const Key('update-manual')), findsNothing);
    expect(find.byKey(const Key('update-primary')), findsOneWidget);

    await tester.tap(find.byKey(const Key('update-primary')));
    await tester.pumpAndSettle();

    expect(downloads, 1);
  });

  testWidgets('no compatible asset in any source offers manual download only',
      (tester) async {
    await _openDialog(
      tester,
      _candidate(
        compatible: false,
        alternates: [_candidate(source: UpdateSource.github, compatible: false)],
      ),
      UpdateDialogDependencies(
        download: (asset, {required cancelToken, required onProgress}) async =>
            package,
        install: (file, {onBeforeExit}) async {},
        openManual: (_) async {},
      ),
    );

    expect(find.byKey(const Key('update-primary')), findsNothing);
    expect(find.byKey(const Key('update-retry')), findsNothing);
    expect(find.byKey(const Key('update-manual')), findsOneWidget);
  });
}
