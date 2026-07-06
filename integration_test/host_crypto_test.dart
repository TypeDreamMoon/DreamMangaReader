import 'dart:convert';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:dream_manga_reader/core/script/crypto_host.dart';
import 'package:dream_manga_reader/core/script/js_engine.dart';

/// 验证 host.crypto.*(md5/HMAC/AES-CBC/base64)在真机上从 JS 可用。
/// 运行:flutter test integration_test/host_crypto_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('host.crypto md5 / hmac / aes / base64', (tester) async {
    final js = JsEngine();
    addTearDown(js.dispose);
    CryptoHost(js);

    // 已知向量
    expect(js.evalSync("host.crypto.md5('abc')"),
        '900150983cd24fb0d6963f7d28e17f72');
    expect(
      js.evalSync(
          "host.crypto.hmacSha256('The quick brown fox jumps over the lazy dog','key')"),
      'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
    );
    expect(js.evalSync("host.crypto.base64Encode('墨')"), '5aKo');
    expect(js.evalSync("host.crypto.base64Decode('5aKo')"), '墨');

    // AES-CBC 往返(通用加密响应解密的回归:16 字节 key/IV,密文 hex)
    final key = enc.Key.fromUtf8('demo-key-16bytes');
    final iv = enc.IV.fromUtf8('1234567890abcdef');
    final encr =
        enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
    const plain = '["a","b","墨染之约"]';
    final cipherHex = encr
        .encrypt(plain, iv: iv)
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    final decoded = js.evalSync(
      "host.crypto.aesCbcDecrypt(${jsonEncode(cipherHex)}, 'demo-key-16bytes', '1234567890abcdef')",
    );
    expect(decoded, plain);
  });
}
