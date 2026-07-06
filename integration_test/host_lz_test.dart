import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lzstring/lzstring.dart';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/lz_host.dart';

/// 验证 host.lz(lz-string)在真机上从 JS 可用:
/// Dart 压缩 → JS 里 host.lz.decompressFromBase64 解压 → 与原文一致。
///
/// 运行:flutter test integration_test/host_lz_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('host.lz decompresses LZString base64 from JS', (tester) async {
    const original = '["墨染之约","银河剑客",{"cid":123456,"files":["/a.jpg"]}]';
    final b64 = await LZString.compressToBase64(original);
    expect(b64, isNotNull);

    final engine = JsEngine();
    addTearDown(engine.dispose);
    LzHost(engine); // 注入 host.lz.*

    final out = engine
        .evalSync('host.lz.decompressFromBase64(${jsonEncode(b64)})');
    expect(out, original);
  });
}
