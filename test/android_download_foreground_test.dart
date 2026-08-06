import 'package:dream_manga_reader/core/downloads/android_download_foreground.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('snapshot includes only active aggregate display state', () {
    final running = taskFixture(state: DownloadTaskState.running).copyWith(
      title: '番剧',
      itemTitle: '第一集',
      completedBytes: 25,
      totalBytes: 100,
      payload: const {
        'sourceId': 'private-source',
        'contentId': 'private-content',
      },
    );
    final queued = taskFixture(
      id: 'novel',
      kind: DownloadContentKind.novel,
    ).copyWith(totalBytes: 0);
    final paused = taskFixture(
      id: 'paused',
      state: DownloadTaskState.paused,
    );

    final snapshot = ContentDownloadForegroundSnapshot.fromTasks([
      paused,
      queued,
      running,
    ]);

    expect(snapshot, isNotNull);
    expect(snapshot.taskCount, 2);
    expect(snapshot.completedBytes, 25);
    expect(snapshot.totalBytes, 100);
    expect(snapshot.indeterminate, isTrue);
    expect(snapshot.currentTitle, '番剧');
    expect(snapshot.currentItemTitle, '第一集');
    expect(
        snapshot.toMap().values.join(' '), isNot(contains('private-source')));
    expect(
        snapshot.toMap().values.join(' '), isNot(contains('private-content')));
  });

  test('bridge starts updates and stops without duplicate native calls',
      () async {
    const channel = MethodChannel('test/content_download_foreground');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final bridge = AndroidDownloadForegroundBridge(
      channel: channel,
      enabled: true,
    );
    final running = taskFixture(state: DownloadTaskState.running);

    await bridge.sync([running]);
    await bridge.sync([running]);
    await bridge.sync([
      running.copyWith(completedBytes: 50, totalBytes: 100),
    ]);
    await bridge.sync(const []);

    expect(calls.map((call) => call.method), ['start', 'update', 'stop']);
  });
}
