import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/log/app_log.dart';
import 'package:dream_manga_reader/main.dart';

void main() {
  // AppLog 记完一条会 notifyListeners,途中要问 SchedulerBinding 当前是不是构建阶段。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppLog.i.clear);

  test('a throwing startup load never escapes', () async {
    await expectLater(
      guardedStartupLoad('炸掉的加载项', () async => throw StateError('boom')),
      completes,
    );
    final failure = AppLog.i.entries.last;
    expect(failure.level, LogLevel.error);
    expect(failure.cat, LogCat.app);
    expect(failure.message, contains('炸掉的加载项'));
    expect(failure.detail, contains('boom'));
  });

  test('one broken load does not sink the rest of the startup batch',
      () async {
    // 这是 runApp 前那一批的形状:六个并发加载,其中一个抛错。裸 Future.wait 会
    // 带着那个错误立刻结束,runApp 永远执行不到 —— 用户看到永久黑窗。
    var okRan = false;
    var lateOkRan = false;
    await Future.wait([
      guardedStartupLoad('好的', () async => okRan = true),
      guardedStartupLoad('炸的', () async => throw Exception('boom')),
      guardedStartupLoad('慢但好的', () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        lateOkRan = true;
      }),
    ]);
    expect(okRan, isTrue);
    // 早失败没有取消掉后面还没完成的那一项。
    expect(lateOkRan, isTrue);
    expect(AppLog.i.entries.where((e) => e.level == LogLevel.error).length, 1);
  });

  test('a failed dependency still lets its dependent run', () async {
    // 代理 → 源清单是真依赖,但代理起不来时源清单照样要试:能直连的源仍可用。
    var sourcesLoaded = false;
    await guardedStartupLoad('代理', () async => throw Exception('no proxy'))
        .then((_) => guardedStartupLoad('源清单', () async {
              sourcesLoaded = true;
            }));
    expect(sourcesLoaded, isTrue);
  });

  test('a successful load logs nothing', () async {
    await guardedStartupLoad('安静的', () async {});
    expect(AppLog.i.entries, isEmpty);
  });
}
