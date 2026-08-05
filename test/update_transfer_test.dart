import 'dart:io';

import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:dream_manga_reader/core/update/update_resolver.dart';
import 'package:dream_manga_reader/core/update/update_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

const _sha256 =
    '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';

const _asset = ResolvedUpdateAsset(
  platform: UpdatePlatform.windows,
  arch: 'x64',
  kind: 'installer',
  fileName: 'setup.exe',
  sha256: _sha256,
  sizeBytes: 3,
  url: 'https://example.com/setup.exe',
  sourceName: 'setup.exe',
);

const _candidate = UpdateCandidate(
  source: UpdateSource.gitee,
  version: '1.7.0',
  tag: 'v1.7.0',
  pageUrl: 'https://example.com/release',
  notes: '',
  prerelease: false,
  assets: [],
  integrity: UpdateIntegrity.manifest,
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dmr-transfer-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('Windows coordinator emits downloading, verifying, then ready',
      () async {
    final package = File('${temp.path}${Platform.pathSeparator}setup.exe')
      ..writeAsBytesSync([1, 2, 3]);
    final coordinator = WindowsUpdateTransferCoordinator(
      download: (asset, {required cancelToken, required onProgress}) async {
        onProgress(.5);
        onProgress(1);
        return package;
      },
      install: (package, {onBeforeExit}) async {},
    );
    final states = <UpdateTransferState>[];
    final subscription = coordinator.states.listen(states.add);

    await coordinator.start(candidate: _candidate, asset: _asset);

    expect(
      states.map((state) => state.stage),
      containsAllInOrder([
        UpdateTransferStage.downloading,
        UpdateTransferStage.verifying,
        UpdateTransferStage.ready,
      ]),
    );
    final current = await coordinator.current();
    expect(current.packagePath, package.path);
    expect(current.taskKey, '$_sha256:1.7.0');
    await subscription.cancel();
    await coordinator.dispose();
  });

  test('cancel returns to idle and keeps the coordinator reusable', () async {
    var attempts = 0;
    final coordinator = WindowsUpdateTransferCoordinator(
      download: (asset, {required cancelToken, required onProgress}) {
        attempts++;
        return cancelToken.whenCancel.then<File>((error) => throw error);
      },
      install: (package, {onBeforeExit}) async {},
    );

    final first = coordinator.start(candidate: _candidate, asset: _asset);
    await coordinator.cancel();
    await first;
    expect((await coordinator.current()).stage, UpdateTransferStage.idle);

    final second = coordinator.start(candidate: _candidate, asset: _asset);
    await coordinator.cancel();
    await second;
    expect(attempts, 2);
    expect((await coordinator.current()).stage, UpdateTransferStage.idle);
    await coordinator.dispose();
  });

  test('install delegates the verified package and before-exit callback',
      () async {
    final package = File('${temp.path}${Platform.pathSeparator}setup.exe')
      ..writeAsBytesSync([1, 2, 3]);
    File? installed;
    var flushed = false;
    final coordinator = WindowsUpdateTransferCoordinator(
      download: (asset, {required cancelToken, required onProgress}) async =>
          package,
      install: (value, {onBeforeExit}) async {
        installed = value;
        await onBeforeExit?.call();
      },
    );

    await coordinator.start(candidate: _candidate, asset: _asset);
    await coordinator.install(onBeforeExit: () async => flushed = true);

    expect(installed?.path, package.path);
    expect(flushed, isTrue);
    await coordinator.dispose();
  });

  test('dispose rejects later starts', () async {
    final coordinator = WindowsUpdateTransferCoordinator(
      download: (asset, {required cancelToken, required onProgress}) async =>
          File('unused'),
      install: (package, {onBeforeExit}) async {},
    );
    await coordinator.dispose();

    await expectLater(
      coordinator.start(candidate: _candidate, asset: _asset),
      throwsA(isA<StateError>()),
    );
  });
}
