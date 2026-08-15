// 未捕获错误的兜底:框架错误与根 zone 异步错误都应落进运行日志(而不是无声消失),
// 同时保留原有的控制台输出行为。
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/log/app_log.dart';
import 'package:dream_manga_reader/core/log/crash_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 三个全局钩子都是进程级的,测试之间必须还原,否则会污染同 isolate 的其他测试。
  setUp(() {
    final savedOnError = FlutterError.onError;
    final savedPresent = FlutterError.presentError;
    final savedPlatform = PlatformDispatcher.instance.onError;
    final savedWidget = ErrorWidget.builder;
    addTearDown(() {
      FlutterError.onError = savedOnError;
      FlutterError.presentError = savedPresent;
      PlatformDispatcher.instance.onError = savedPlatform;
      ErrorWidget.builder = savedWidget;
    });
    AppLog.i.clear();
  });

  List<LogEntry> crashes() =>
      AppLog.i.entries.where((e) => e.cat == LogCat.crash).toList();

  test('框架错误既进日志,也仍然交给原有 handler', () {
    // 装成「上一手」,以此断言链式调用没把原行为吞掉。
    final passedOn = <FlutterErrorDetails>[];
    FlutterError.onError = passedOn.add;

    installCrashGuard();
    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('boom'),
      stack: StackTrace.fromString('#0 someFrame'),
      library: 'widgets library',
      context: ErrorDescription('building MyWidget'),
    ));

    expect(crashes(), hasLength(1), reason: '框架错误应记一条异常日志');
    expect(crashes().single.level, LogLevel.error);
    expect(crashes().single.message, contains('boom'));
    expect(crashes().single.message, contains('building MyWidget'),
        reason: 'context 是定位用的,要出现在主行');
    expect(crashes().single.detail, contains('someFrame'),
        reason: '堆栈折进 detail');
    expect(passedOn, hasLength(1),
        reason: '原有 handler(默认是控制台 dump)必须保留,不能被吞');
  });

  test('silent 的框架错误不记(框架自己吞掉的连锁错误,避免刷屏)', () {
    FlutterError.onError = (_) {};
    installCrashGuard();
    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('quiet'),
      silent: true,
    ));

    expect(crashes(), isEmpty);
  });

  test('根 zone 异步错误记一次,并声明已处理', () {
    final presented = <FlutterErrorDetails>[];
    FlutterError.presentError = presented.add; // 拦下控制台输出,顺便断言
    FlutterError.onError = (_) {};

    installCrashGuard();
    final handled = PlatformDispatcher.instance.onError!(
      StateError('async boom'),
      StackTrace.fromString('#0 asyncFrame'),
    );

    expect(handled, isTrue, reason: '返回 true = 已处理,不再上抛给平台默认处理器');
    expect(crashes(), hasLength(1),
        reason: '走 presentError 而不是 FlutterError.onError,否则同一条会记两次');
    expect(crashes().single.detail, contains('asyncFrame'));
    expect(presented, hasLength(1), reason: '控制台那份仍要打印');
  });

  test('长堆栈截断,不把 800 条的日志缓冲挤爆', () {
    FlutterError.onError = (_) {};
    installCrashGuard();
    final long =
        List.generate(400, (i) => '#$i frame$i').join('\n');
    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('deep'),
      stack: StackTrace.fromString(long),
    ));

    final detail = crashes().single.detail!;
    expect(detail, contains('#0 frame0'), reason: '出错点在最上面,必须留着');
    expect(detail, isNot(contains('#399 frame399')));
    expect(detail, contains('另有'), reason: '截断要留下计数,别假装堆栈就这么短');
    expect(detail.split('\n').length, lessThan(40));
  });

  test('记录失败也不再抛(错误处理里出错会变成死循环)', () {
    FlutterError.onError = (_) {};
    installCrashGuard();

    // toString 自己就抛的异常对象:_record 内部必须扛住。
    expect(
      () => FlutterError.onError!(
        FlutterErrorDetails(exception: _HostileError()),
      ),
      returnsNormally,
    );
  });
}

/// toString 抛异常的错误对象 —— 记录路径上的每一步都得容得下它。
class _HostileError implements Exception {
  @override
  String toString() => throw StateError('toString exploded');
}
