// 首帧后那批加载(三本书架 → 自动上传监听 → 启动同步 → 追更检查)串在一条
// `Future.wait(...).then(...)` 上,过去没有任何 catchError:任何一环抛错,后面几环
// 全被跳过,错误还没人接。这里把持久化层整个打成会抛的,确认外壳照样起得来,
// 并且每一环的失败都被单独记进了运行日志。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/app/app.dart';
import 'package:dream_manga_reader/core/log/app_log.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppLog.i.clear();
    // 读档全线失败:损坏的偏好文件 / 拿不到的存储,在真机上都长这样。
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => throw PlatformException(code: 'unavailable'),
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      null,
    );
  });

  testWidgets('the shell still boots when every persisted load throws',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const App());
    await tester.pump();
    // initState 里那条链是真异步(插件通道往返),得让真实时间走一段才跑得完。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);

    final failures = AppLog.i.entries
        .where((e) => e.level == LogLevel.error && e.cat == LogCat.app)
        .map((e) => e.message)
        .toList();
    // 三本书架各自记一条,而不是第一本抛完就整条链没了。
    expect(failures, contains('启动加载失败 · 漫画书架'));
    expect(failures, contains('启动加载失败 · 小说书架'));
    expect(failures, contains('启动加载失败 · 番剧书架'));
    // 书架读档全挂了,后面几步照样跑到了。
    expect(
      AppLog.i.entries.any((e) => e.message.contains('自动上传监听')),
      isTrue,
      reason: '书架读档失败不该把 .then 里的后续步骤一起吞掉',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
