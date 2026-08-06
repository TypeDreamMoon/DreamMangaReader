import 'dart:async';

import 'package:dream_manga_reader/core/update/android_update_bridge.dart';
import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:dream_manga_reader/core/update/update_resolver.dart';
import 'package:dream_manga_reader/core/update/update_transfer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _shaA =
    '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';
const _shaB =
    'ae4b3280e56e2faf83f414a6e3dabe9d5fbe18976544c05fed121accb85b53fc';

const _asset = ResolvedUpdateAsset(
  platform: UpdatePlatform.android,
  arch: 'arm64-v8a',
  kind: 'installer',
  fileName: 'DreamMangaReader.apk',
  sha256: _shaA,
  sizeBytes: 3,
  url: 'https://foruda.gitee.com/DreamMangaReader.apk?token=secret&ts=1',
  sourceName: 'DreamMangaReader.apk',
);

const _chunkedAsset = ResolvedUpdateAsset(
  platform: UpdatePlatform.android,
  arch: 'universal',
  kind: 'installer',
  fileName: 'DreamMangaReader.apk',
  sha256: _shaA,
  sizeBytes: 3,
  parts: [
    ResolvedUpdatePart(
      fileName: 'DreamMangaReader.apk.part001',
      sha256: _shaA,
      sizeBytes: 2,
      url: 'https://example.com/app.part001',
      sourceName: 'app.part001',
    ),
    ResolvedUpdatePart(
      fileName: 'DreamMangaReader.apk.part002',
      sha256: _shaB,
      sizeBytes: 1,
      url: 'https://example.com/app.part002',
      sourceName: 'app.part002',
    ),
  ],
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

class _FakeBridge implements AndroidUpdateBridgeApi {
  final controller = StreamController<AndroidUpdateState>.broadcast();
  AndroidUpdateState currentState =
      const AndroidUpdateState(stage: UpdateTransferStage.idle);
  AndroidUpdatePlan? started;
  var cancels = 0;
  var installs = 0;

  @override
  Future<void> cancel() async => cancels++;

  @override
  Future<AndroidUpdateState> current() async => currentState;

  @override
  Future<void> installReady() async => installs++;

  @override
  Future<void> start(AndroidUpdatePlan plan) async => started = plan;

  @override
  Stream<AndroidUpdateState> get states => controller.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidUpdateBridge.methodChannel, null);
  });

  test('serializes a direct Android plan', () {
    final json = AndroidUpdatePlan.fromAsset(
      versionName: '1.7.0',
      asset: _asset,
    ).toJson();

    expect(json['schemaVersion'], 1);
    expect(json['taskKey'], '$_shaA:1.7.0');
    expect(json['url'], _asset.url);
    expect(json.containsKey('parts'), isFalse);
  });

  test('serializes a chunked Android plan', () {
    final json = AndroidUpdatePlan.fromAsset(
      versionName: '1.7.0',
      asset: _chunkedAsset,
    ).toJson();

    expect(json.containsKey('url'), isFalse);
    expect((json['parts'] as List).length, 2);
    expect(json['sizeBytes'], 3);
  });

  test('rejects unsafe or non-HTTPS download plans before native code', () {
    for (final asset in [
      const ResolvedUpdateAsset(
        platform: UpdatePlatform.windows,
        arch: 'x64',
        kind: 'installer',
        fileName: 'setup.exe',
        sha256: _shaA,
        sizeBytes: 3,
        url: 'https://example.com/setup.exe',
      ),
      const ResolvedUpdateAsset(
        platform: UpdatePlatform.android,
        arch: 'arm64-v8a',
        kind: 'installer',
        fileName: '../app.apk',
        sha256: _shaA,
        sizeBytes: 3,
        url: 'https://example.com/app.apk',
      ),
      const ResolvedUpdateAsset(
        platform: UpdatePlatform.android,
        arch: 'arm64-v8a',
        kind: 'installer',
        fileName: 'app.apk',
        sha256: _shaA,
        sizeBytes: 3,
        url: 'http://example.com/app.apk',
      ),
    ]) {
      expect(
        () => AndroidUpdatePlan.fromAsset(
          versionName: '1.7.0',
          asset: asset,
        ),
        throwsFormatException,
      );
    }
  });

  test('decodes a persisted ready state', () {
    final state = AndroidUpdateState.fromJson({
      'status': 'ready',
      'taskKey': '$_shaA:1.7.0',
      'versionName': '1.7.0',
      'downloadedBytes': 30,
      'totalBytes': 30,
      'percent': 100.0,
      'apkPath': '/data/user/0/app/files/updates/app.apk',
    });

    expect(state.stage, UpdateTransferStage.ready);
    expect(state.packagePath, endsWith('app.apk'));
    expect(state.progress, 1);
  });

  test('rejects unknown and internally inconsistent native states', () {
    expect(
      () => AndroidUpdateState.fromJson(const {'status': 'mystery'}),
      throwsFormatException,
    );
    expect(
      () => AndroidUpdateState.fromJson(const {
        'status': 'downloading',
        'downloadedBytes': 4,
        'totalBytes': 3,
        'percent': 120,
      }),
      throwsFormatException,
    );
    expect(
      () => AndroidUpdateState.fromJson(const {
        'status': 'ready',
        'downloadedBytes': 3,
        'totalBytes': 3,
        'percent': 100,
      }),
      throwsFormatException,
    );
  });

  test('redacts signed URL query parameters from platform errors', () {
    final sanitized = sanitizeUpdateError(
      'Connection closed, uri='
      'https://foruda.gitee.com/a.apk?token=secret&ts=1 next',
    );

    expect(sanitized, contains('https://foruda.gitee.com/a.apk'));
    expect(sanitized, isNot(contains('secret')));
    expect(sanitized, isNot(contains('token=')));
    expect(sanitized, isNot(contains('ts=')));
    // 整个 query 必须消失,而不只是那些恰好叫 token/ts 的参数。
    expect(sanitized, isNot(contains('?')));
  });

  test('strips arbitrary signature parameters, not just token and ts', () {
    final sanitized = sanitizeUpdateError(
      'download failed https://cdn.example.com/app.apk'
      '?X-Amz-Signature=deadbeef&sig=zzz&expires=1',
    );

    expect(sanitized, contains('https://cdn.example.com/app.apk'));
    expect(sanitized, isNot(contains('deadbeef')));
    expect(sanitized, isNot(contains('zzz')));
    expect(sanitized, isNot(contains('X-Amz-Signature')));
  });

  test('redacts bare credential parameters without emitting a literal group ref',
      () {
    // 这些 token 不在 URL 里,所以走的是分组替换那一步。用 replaceAll 时 Dart 不解释
    // `$1`,输出会变成字面量 "$1=[redacted]"。
    final sanitized = sanitizeUpdateError('auth failed token=abc123 ts=99');

    expect(sanitized, 'auth failed token=[redacted] ts=[redacted]');
    expect(sanitized, isNot(contains(r'$1')));
    expect(sanitized, isNot(contains('abc123')));
  });

  test('bridge invokes the native method contract', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidUpdateBridge.methodChannel,
            (call) async {
      calls.add(call);
      if (call.method == 'getUpdateDownloadState') {
        return <String, Object?>{'status': 'idle'};
      }
      return null;
    });
    final bridge = AndroidUpdateBridge();
    final plan = AndroidUpdatePlan.fromAsset(
      versionName: '1.7.0',
      asset: _asset,
    );

    await bridge.start(plan);
    await bridge.current();
    await bridge.installReady();
    await bridge.cancel();

    expect(calls.map((call) => call.method), [
      'startUpdateDownload',
      'getUpdateDownloadState',
      'installReadyUpdate',
      'cancelUpdateDownload',
    ]);
  });

  test('Android coordinator starts plans and forwards native state', () async {
    final bridge = _FakeBridge();
    final coordinator = AndroidUpdateTransferCoordinator(bridge);
    final states = <UpdateTransferState>[];
    final subscription = coordinator.states.listen(states.add);

    await coordinator.start(candidate: _candidate, asset: _asset);
    bridge.controller.add(const AndroidUpdateState(
      stage: UpdateTransferStage.retrying,
      retryAttempt: 2,
      progress: .4,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(bridge.started?.toJson()['taskKey'], '$_shaA:1.7.0');
    expect(coordinator.supportsBackground, isTrue);
    expect(states.last.stage, UpdateTransferStage.retrying);
    await coordinator.cancel();
    await coordinator.install();
    expect(bridge.cancels, 1);
    expect(bridge.installs, 1);
    await subscription.cancel();
    await coordinator.dispose();
    await bridge.controller.close();
  });
}
