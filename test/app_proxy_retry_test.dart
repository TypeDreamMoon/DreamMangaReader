import 'dart:async';
import 'dart:io';

import 'package:dream_manga_reader/core/net/app_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假的 reg.exe / powershell.exe:按程序名回预设结果,并记下被调了哪些。
class _FakeProcesses {
  _FakeProcesses({this.reg, this.powershell});

  final ProcessResult Function(List<String> args)? reg;
  final ProcessResult Function(List<String> args)? powershell;
  final List<String> calls = [];

  Future<ProcessResult> run(String exe, List<String> args) async {
    calls.add(exe);
    final h = exe == 'reg' ? reg : powershell;
    if (h == null) throw ProcessException(exe, args, '起不来', 5);
    return h(args);
  }
}

ProcessResult _ok(String stdout) => ProcessResult(1, 0, stdout, '');

const _regEnabled0 = '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\'
    'CurrentVersion\\Internet Settings\r\n    ProxyEnable    REG_DWORD    0x0\r\n';
const _regEnabled1 = '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\'
    'CurrentVersion\\Internet Settings\r\n    ProxyEnable    REG_DWORD    0x1\r\n';

final _proxy = AppProxy.parse('127.0.0.1:7890').endpoint!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final realRunProcess = AppProxy.debugRunProcess;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppProxy.debugResetRetryDetect();
    AppProxy.debugClock = DateTime.now;
    // 起点:自动模式、什么都没探到(不取决于跑测试那台机器开没开代理)
    AppProxy.debugDetectAuto = () async => (null, ProxySource.directNoProxy);
    await AppProxy.setOverride(null);
  });

  tearDown(() {
    HttpOverrides.global = null;
    AppProxy.debugDetectAuto = null;
    AppProxy.debugRunProcess = realRunProcess;
    AppProxy.debugClock = DateTime.now;
    AppProxy.debugResetRetryDetect();
  });

  group('windows 系统代理探测', () {
    test('reg.exe 跑通且 ProxyEnable=0 → 直连,不再起 PowerShell', () async {
      final fake = _FakeProcesses(
        reg: (_) => _ok(_regEnabled0),
        powershell: (_) => _ok('127.0.0.1:9999'),
      );
      AppProxy.debugRunProcess = fake.run;

      expect(await AppProxy.debugWindowsSystemProxy(), isNull);
      expect(fake.calls, ['reg']);
    });

    test('reg.exe 读到代理 → 直接用,不起 PowerShell', () async {
      final fake = _FakeProcesses(
        reg: (args) => args.contains('ProxyEnable')
            ? _ok(_regEnabled1)
            : _ok('    ProxyServer    REG_SZ    '
                'http=127.0.0.1:7890;https=127.0.0.1:7891\r\n'),
      );
      AppProxy.debugRunProcess = fake.run;

      expect(await AppProxy.debugWindowsSystemProxy(), '127.0.0.1:7891');
      expect(fake.calls, ['reg', 'reg']);
    });

    test('reg.exe 起不来(被安全软件拦)→ 退 PowerShell', () async {
      final fake = _FakeProcesses(
        powershell: (_) => _ok('127.0.0.1:7890\r\n'),
      );
      AppProxy.debugRunProcess = fake.run;

      expect(await AppProxy.debugWindowsSystemProxy(), '127.0.0.1:7890');
      expect(fake.calls, ['reg', 'powershell']);
    });

    test('reg.exe 被组策略拒绝(非 0 退出)→ 退 PowerShell', () async {
      final fake = _FakeProcesses(
        reg: (_) => ProcessResult(
            1, 1, '', 'ERROR: Registry editing has been disabled by your administrator.'),
        powershell: (_) => _ok('127.0.0.1:7890'),
      );
      AppProxy.debugRunProcess = fake.run;

      expect(await AppProxy.debugWindowsSystemProxy(), '127.0.0.1:7890');
      expect(fake.calls, ['reg', 'powershell']);
    });
  });

  group('retryDetect', () {
    test('并发失败只探一次(single-flight),generation 只涨一次', () async {
      var detects = 0;
      final gate = Completer<void>();
      AppProxy.debugDetectAuto = () async {
        detects++;
        await gate.future;
        return (_proxy, ProxySource.systemProxy);
      };
      final before = AppProxy.generation;

      final results = [for (var i = 0; i < 20; i++) AppProxy.retryDetect()];
      gate.complete();
      final all = await Future.wait(results);

      expect(detects, 1);
      expect(all, everyElement(isTrue)); // 等到的都知道「有代理了,可以重试」
      expect(AppProxy.generation, before + 1);
      expect(AppProxy.current, '127.0.0.1:7890');
      expect(AppProxy.sourceCode, ProxySource.systemProxy);

      // 已经有代理了:再失败也不再探
      expect(await AppProxy.retryDetect(), isFalse);
      expect(detects, 1);
    });

    test('没探到:generation 不涨;冷却期内不再起进程,过了冷却再探', () async {
      var now = DateTime(2026, 11, 8, 12);
      AppProxy.debugClock = () => now;
      var detects = 0;
      AppProxy.debugDetectAuto = () async {
        detects++;
        return (null, ProxySource.directNoProxy);
      };
      final before = AppProxy.generation;

      expect(await AppProxy.retryDetect(), isFalse);
      expect(detects, 1);
      expect(AppProxy.generation, before, reason: '什么都没变,长命 client 不必重建');

      now = now.add(const Duration(seconds: 5));
      for (var i = 0; i < 10; i++) {
        expect(await AppProxy.retryDetect(), isFalse);
      }
      expect(detects, 1, reason: '冷却期内不再探');

      now = now.add(AppProxy.retryDetectCooldown);
      expect(await AppProxy.retryDetect(), isFalse);
      expect(detects, 2);
    });

    test('手动设过代理 / 强制直连时不干预', () async {
      var detects = 0;
      AppProxy.debugDetectAuto = () async {
        detects++;
        return (_proxy, ProxySource.systemProxy);
      };
      await AppProxy.setOverride('DIRECT');
      expect(await AppProxy.retryDetect(), isFalse);
      expect(detects, 0);
    });
  });
}
