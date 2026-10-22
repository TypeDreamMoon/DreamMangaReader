import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// `integration_test/scroll_profile_test.dart` 的主机侧驱动。
///
/// `watchPerformance` 的汇总不会回给设备端测试,而是塞进 `reportData` 由这里落盘 ——
/// 所以「改一条 → 跑一次 → 比数字」的对比物料就靠这个文件。
///
/// 用法:
/// ```
/// flutter drive --driver=test_driver/integration_test.dart \
///   --target=integration_test/scroll_profile_test.dart \
///   --profile -d <device> --dart-define=PROFILE_LABEL=baseline
/// ```
Future<void> main() => integrationDriver(
      responseDataCallback: (data) async {
        final json =
            const JsonEncoder.withIndent('  ').convert(data ?? const <String, dynamic>{});
        final dir = Directory('build/scroll_profile')
          ..createSync(recursive: true);
        final stamp = DateTime.now()
            .toIso8601String()
            .replaceAll(':', '')
            .replaceAll('.', '');
        final file = File('${dir.path}/scroll_$stamp.json')
          ..writeAsStringSync(json);
        stdout.writeln('SCROLL_PROFILE_FILE=${file.path}');
        stdout.writeln(json);
      },
    );
