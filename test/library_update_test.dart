// 追更:账本(算「新增几话」)与扫描器(并发、容错、统计)。
//
// 这里最该测住的是**首次收藏不该炸出一屏「500 话新」**,以及**源出错不能被
// 当成「0 话」压坏基线** —— 两个都是一旦写错就会把角标变成噪音的地方。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_manga_reader/core/library/update_checker.dart';
import 'package:dream_manga_reader/core/library/update_tracker.dart';

const _t0 = 1700000000000; // 固定时间戳:测试不依赖真实时钟

UpdateTarget _target(String key, {String title = 'T'}) => UpdateTarget(
      shelfKey: key,
      sourceId: 'src',
      itemId: key,
      title: title,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LibraryUpdateTracker', () {
    late LibraryUpdateTracker tracker;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tracker = LibraryUpdateTracker();
      await tracker.load();
    });

    test('首次检查只立基线,不报「新」', () {
      final gained = tracker.recordCheck('manga:a', 500, now: _t0);

      expect(gained, 0, reason: '第一次数它,不是它更新了');
      expect(tracker.pendingFor('manga:a'), 0,
          reason: '刚收藏一部 500 话完结老番,不该整屏角标');
      expect(tracker.markFor('manga:a')!.latest, 500);
    });

    test('第二次多出来的才算新', () {
      tracker.recordCheck('manga:a', 100, now: _t0);
      final gained = tracker.recordCheck('manga:a', 103, now: _t0 + 1);

      expect(gained, 3);
      expect(tracker.pendingFor('manga:a'), 3);
      expect(tracker.pendingWorks, 1);
    });

    test('连着更新两次,角标累加而不是只记最后一次', () {
      tracker.recordCheck('manga:a', 100, now: _t0);
      tracker.recordCheck('manga:a', 102, now: _t0 + 1);
      tracker.recordCheck('manga:a', 105, now: _t0 + 2);

      expect(tracker.pendingFor('manga:a'), 5, reason: '用户一次都没看过,5 话都是新的');
    });

    test('看过之后归零,但基线留着', () {
      tracker.recordCheck('manga:a', 100, now: _t0);
      tracker.recordCheck('manga:a', 104, now: _t0 + 1);
      tracker.markSeen('manga:a');

      expect(tracker.pendingFor('manga:a'), 0);
      expect(tracker.recordCheck('manga:a', 106, now: _t0 + 2), 2,
          reason: '下次比较的基线应是 104,不是回到 100');
    });

    test('查到 0 话当作源出错,不动基线', () {
      tracker.recordCheck('manga:a', 100, now: _t0);
      final gained = tracker.recordCheck('manga:a', 0, now: _t0 + 1);

      expect(gained, 0);
      expect(tracker.markFor('manga:a')!.latest, 100,
          reason: '源抽风返回空目录,不能把 100 话抹成 0');
    });

    test('目录变短:跟着降,且涨回原位时不误报', () {
      tracker.recordCheck('manga:a', 100, now: _t0);
      tracker.recordCheck('manga:a', 90, now: _t0 + 1); // 源下架了 10 话
      expect(tracker.pendingFor('manga:a'), 0);

      final gained = tracker.recordCheck('manga:a', 100, now: _t0 + 2);
      expect(gained, 10,
          reason: '基线已压到 90,涨回 100 就是 10 话新 —— 这是源的口径,不是我们的');
    });

    test('全部标为已看', () {
      tracker.recordCheck('a', 10, now: _t0);
      tracker.recordCheck('b', 10, now: _t0);
      tracker.recordCheck('a', 12, now: _t0 + 1);
      tracker.recordCheck('b', 15, now: _t0 + 1);
      expect(tracker.pendingWorks, 2);

      tracker.markAllSeen();
      expect(tracker.pendingWorks, 0);
    });

    test('retainOnly 回收已取消收藏的记录', () {
      tracker.recordCheck('a', 10, now: _t0);
      tracker.recordCheck('b', 10, now: _t0);

      tracker.retainOnly({'a'});

      expect(tracker.markFor('a'), isNotNull);
      expect(tracker.markFor('b'), isNull, reason: '账本不能随收藏来回增删无限长大');
    });

    test('重启后账本与开关都读得回来', () async {
      tracker.recordCheck('manga:a', 10, now: _t0);
      tracker.recordCheck('manga:a', 13, now: _t0 + 1);
      tracker.autoCheck = false;
      tracker.recordSweep(_t0 + 1);

      final restarted = LibraryUpdateTracker();
      await restarted.load();

      expect(restarted.pendingFor('manga:a'), 3);
      expect(restarted.autoCheck, isFalse);
      expect(restarted.sweepDue(_t0 + 1), isFalse, reason: '刚扫过,不该立刻又扫');
      expect(
          restarted.sweepDue(
              _t0 + 1 + LibraryUpdateTracker.autoInterval.inMilliseconds),
          isTrue);
    });

    test('存档损坏时当作没有记录,不影响书架', () async {
      SharedPreferences.setMockInitialValues({'lib.updateMarks': '{不是 JSON'});
      final t = LibraryUpdateTracker();

      await expectLater(t.load(), completes);
      expect(t.pendingWorks, 0);
    });
  });

  group('LibraryUpdateChecker', () {
    late LibraryUpdateTracker tracker;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tracker = LibraryUpdateTracker();
      await tracker.load();
    });

    test('扫一遍全部收藏,统计有更新的本数与话数', () async {
      // 先立基线,再让第二轮各多几话。
      for (final k in ['a', 'b', 'c']) {
        tracker.recordCheck(k, 10, now: _t0);
      }
      final counts = {'a': 12, 'b': 10, 'c': 15};
      final checker = LibraryUpdateChecker(
        tracker: tracker,
        fetcher: (t) async => counts[t.shelfKey],
      );

      final r = await checker.sweep(
        [for (final k in counts.keys) _target(k)],
        now: _t0 + 1,
      );

      expect(r.checked, 3);
      expect(r.failed, 0);
      expect(r.updatedWorks, 2, reason: 'b 没更新');
      expect(r.newChapters, 7, reason: 'a 的 2 话 + c 的 5 话');
      expect(r.hasUpdates, isTrue);
    });

    test('一本查不动不中断整轮', () async {
      for (final k in ['a', 'b', 'c']) {
        tracker.recordCheck(k, 10, now: _t0);
      }
      final checker = LibraryUpdateChecker(
        tracker: tracker,
        fetcher: (t) async {
          if (t.shelfKey == 'b') throw StateError('源挂了');
          return 12;
        },
      );

      final r = await checker.sweep(
        [_target('a'), _target('b'), _target('c')],
        now: _t0 + 1,
      );

      expect(r.failed, 1);
      expect(r.checked, 2, reason: '死一个源不该把其余两本的结论也吞掉');
      expect(r.updatedWorks, 2);
    });

    test('fetcher 返回 null 记失败,且不动基线', () async {
      tracker.recordCheck('a', 100, now: _t0);
      final checker = LibraryUpdateChecker(
        tracker: tracker,
        fetcher: (_) async => null,
      );

      final r = await checker.sweep([_target('a')], now: _t0 + 1);

      expect(r.failed, 1);
      expect(r.checked, 0);
      expect(tracker.markFor('a')!.latest, 100,
          reason: 'null 是「这次没查到」,不是「现在 0 话」');
    });

    test('并发受限,但每一本都查到', () async {
      var inFlight = 0;
      var peak = 0;
      final checker = LibraryUpdateChecker(
        tracker: tracker,
        concurrency: 3,
        fetcher: (t) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(Duration.zero);
          inFlight--;
          return 5;
        },
      );

      final targets = [for (var i = 0; i < 12; i++) _target('k$i')];
      final r = await checker.sweep(targets, now: _t0);

      expect(r.checked, 12, reason: '一本都不能漏');
      expect(peak, lessThanOrEqualTo(3), reason: '源站经不起并发轰炸');
    });

    test('进度回调一本一次,最后一次是满的', () async {
      final seen = <(int, int)>[];
      final checker = LibraryUpdateChecker(
        tracker: tracker,
        fetcher: (_) async => 5,
      );

      await checker.sweep(
        [for (var i = 0; i < 4; i++) _target('k$i')],
        now: _t0,
        onProgress: (done, total) => seen.add((done, total)),
      );

      expect(seen, hasLength(4));
      expect(seen.last, (4, 4));
    });

    test('扫描期间重复触发直接返回,不叠第二轮', () async {
      var calls = 0;
      final checker = LibraryUpdateChecker(
        tracker: tracker,
        fetcher: (_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 5;
        },
      );
      final targets = [_target('a'), _target('b')];

      final first = checker.sweep(targets, now: _t0);
      final second = await checker.sweep(targets, now: _t0); // 扫描仍在进行
      await first;

      expect(second.checked, 0, reason: '重入应被挡掉');
      expect(calls, 2, reason: '只有第一轮的两本被查');
    });

    test('空书架直接收工,也不刷新扫描时间', () async {
      final checker =
          LibraryUpdateChecker(tracker: tracker, fetcher: (_) async => 5);

      final r = await checker.sweep(const [], now: _t0);

      expect(r.checked, 0);
      expect(r.hasUpdates, isFalse);
      expect(tracker.lastSweepAt, 0);
    });

    test('扫完顺手回收不在书架上的记录', () async {
      tracker.recordCheck('gone', 10, now: _t0);
      final checker =
          LibraryUpdateChecker(tracker: tracker, fetcher: (_) async => 5);

      await checker.sweep([_target('alive')], now: _t0 + 1);

      expect(tracker.markFor('gone'), isNull);
      expect(tracker.markFor('alive'), isNotNull);
      expect(tracker.lastSweepAt, _t0 + 1);
    });
  });
}
