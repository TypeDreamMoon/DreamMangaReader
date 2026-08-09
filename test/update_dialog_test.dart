import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:dream_manga_reader/core/update/update_downloader.dart';
import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:dream_manga_reader/core/update/update_resolver.dart';
import 'package:dream_manga_reader/core/update/update_service.dart';
import 'package:dream_manga_reader/core/update/update_transfer.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _sha256 =
    '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';

UpdateCandidate _candidate({
  UpdateSource source = UpdateSource.gitee,
  bool compatible = true,
  String assetUrl = 'https://example/setup.exe',
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
    assets: [
      RemoteAsset(
        name: fileName,
        url: assetUrl,
        size: 3,
      ),
    ],
    integrity: UpdateIntegrity.manifest,
    manifest: manifest,
    alternates: alternates,
  );
}

class _FakeCoordinator implements UpdateTransferCoordinator {
  _FakeCoordinator({
    this.initial = const UpdateTransferState.idle(),
  });

  UpdateTransferState initial;
  final controller = StreamController<UpdateTransferState>.broadcast();
  var startCount = 0;
  var cancelCount = 0;
  var installCount = 0;
  ResolvedUpdateAsset? startedAsset;

  @override
  bool get supportsBackground => true;

  @override
  Stream<UpdateTransferState> get states => controller.stream;

  void emit(UpdateTransferState state) {
    initial = state;
    controller.add(state);
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    emit(const UpdateTransferState.idle());
  }

  @override
  Future<UpdateTransferState> current() async => initial;

  @override
  Future<void> dispose() async {}

  @override
  Future<void> install({Future<void> Function()? onBeforeExit}) async {
    installCount++;
  }

  @override
  Future<void> start({
    required UpdateCandidate candidate,
    required ResolvedUpdateAsset asset,
  }) async {
    startCount++;
    startedAsset = asset;
  }
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

  testWidgets(
      'switches to the alternate source when the preferred one has no '
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
        alternates: [
          _candidate(source: UpdateSource.github, compatible: false)
        ],
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

  testWidgets('background button closes without cancelling Android transfer',
      (tester) async {
    final coordinator = _FakeCoordinator();
    await _openDialog(
      tester,
      _candidate(),
      UpdateDialogDependencies.coordinator(
        coordinator: coordinator,
        refresh: (_) async => null,
        openManual: (_) async {},
      ),
    );

    await tester.tap(find.byKey(const Key('update-primary')));
    coordinator.emit(const UpdateTransferState(
      stage: UpdateTransferStage.downloading,
      taskKey: '$_sha256:1.3.1',
      versionName: '1.3.1',
      progress: .25,
      downloadedBytes: 1,
      totalBytes: 3,
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('update-background')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(coordinator.cancelCount, 0);
  });

  testWidgets('restores an existing transfer without starting a duplicate',
      (tester) async {
    final coordinator = _FakeCoordinator(
      initial: const UpdateTransferState(
        stage: UpdateTransferStage.downloading,
        taskKey: '$_sha256:1.3.1',
        versionName: '1.3.1',
        progress: .6,
        downloadedBytes: 2,
        totalBytes: 3,
      ),
    );
    await _openDialog(
      tester,
      _candidate(),
      UpdateDialogDependencies.coordinator(
        coordinator: coordinator,
        refresh: (_) async => null,
        openManual: (_) async {},
      ),
    );

    expect(find.textContaining('60%'), findsOneWidget);
    expect(coordinator.startCount, 0);
  });

  testWidgets('returning to the foreground re-syncs a stale verifying state',
      (tester) async {
    const taskKey = '$_sha256:1.3.1';
    final coordinator = _FakeCoordinator(
      initial: const UpdateTransferState(
        stage: UpdateTransferStage.verifying,
        taskKey: taskKey,
        versionName: '1.3.1',
        progress: 1,
        downloadedBytes: 3,
        totalBytes: 3,
      ),
    );
    await _openDialog(
      tester,
      _candidate(),
      UpdateDialogDependencies.coordinator(
        coordinator: coordinator,
        refresh: (_) async => null,
        openManual: (_) async {},
      ),
    );

    expect(find.text('正在校验安装包…'), findsOneWidget);
    expect(find.byKey(const Key('update-install')), findsNothing);

    // 后台下载期间事件丢了:原生早就 ready,对话框却停在「正在校验安装包」。
    // 回到前台必须自己对一次状态,否则永远等不到安装按钮。
    coordinator.initial = const UpdateTransferState(
      stage: UpdateTransferStage.ready,
      taskKey: taskKey,
      versionName: '1.3.1',
      progress: 1,
      downloadedBytes: 3,
      totalBytes: 3,
      packagePath: '/data/updates/app.apk',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('update-install')), findsOneWidget);
    expect(coordinator.installCount, 0);
  });

  testWidgets('expired URL refreshes the asset before retry', (tester) async {
    final coordinator = _FakeCoordinator(
      initial: const UpdateTransferState(
        stage: UpdateTransferStage.error,
        taskKey: '$_sha256:1.3.1',
        versionName: '1.3.1',
        errorCode: 'expired_url',
        message: 'expired',
      ),
    );
    var refreshes = 0;
    await _openDialog(
      tester,
      _candidate(),
      UpdateDialogDependencies.coordinator(
        coordinator: coordinator,
        refresh: (_) async {
          refreshes++;
          return _candidate(assetUrl: 'https://example/fresh.apk?token=new');
        },
        openManual: (_) async {},
      ),
    );

    await tester.tap(find.byKey(const Key('update-retry')));
    await tester.pumpAndSettle();

    expect(refreshes, 1);
    expect(coordinator.startedAsset?.url, contains('fresh.apk'));
  });
}
