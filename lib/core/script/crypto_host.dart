import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;

import 'js_engine.dart';

/// 把常用加解密以 `host.crypto.*` 暴露给 JS 源(通用原语,不针对任何具体站点):
/// - `md5(str)` → hex(切片解扰的 band 数、各种签名)
/// - `hmacSha256(msg, key)` → hex(请求签名)
/// - `aesCbcDecrypt(cipherHex, keyUtf8, ivUtf8)` → 明文(key/iv 取 UTF-8 字节)
/// - `aesCbcDecryptHex(cipherHex, keyHex, ivHex)` → 明文(key/iv 是**原始字节的 hex**,
///   给「二进制 key/IV」的站点用;如 IV 内嵌在密文头部)
/// - `base64Decode/Encode(str)`(文本)、`base64ToHex(b64)` → hex(**二进制安全**,
///   给「base64 里是二进制、不能按 UTF-8 解」的场景)
class CryptoHost {
  CryptoHost(JsEngine engine) {
    engine.onMessage('crypto', _handle);
    engine.evalSync(_bootstrapJs);
  }

  Object? _handle(dynamic message) {
    final args = message as List;
    final op = args[0] as String;
    switch (op) {
      case 'md5':
        return crypto.md5.convert(utf8.encode(args[1] as String)).toString();
      case 'hmacSha256':
        final mac = crypto.Hmac(crypto.sha256, utf8.encode(args[2] as String))
            .convert(utf8.encode(args[1] as String));
        return mac.toString();
      case 'aesCbcDecrypt':
        return _aesCbcDecrypt(
            args[1] as String, args[2] as String, args[3] as String);
      case 'aesCbcDecryptHex':
        return _aesCbcDecryptHex(
            args[1] as String, args[2] as String, args[3] as String);
      case 'base64Decode':
        return utf8.decode(base64.decode(args[1] as String),
            allowMalformed: true);
      case 'base64Encode':
        return base64.encode(utf8.encode(args[1] as String));
      case 'base64ToHex':
        return _hexEncode(base64.decode(args[1] as String));
      default:
        return null;
    }
  }

  /// AES-128/256-CBC + PKCS7。key/iv 取 UTF-8 字节;密文为 hex。返回明文字符串。
  String _aesCbcDecrypt(String cipherHex, String keyStr, String ivStr) {
    final key = enc.Key(Uint8List.fromList(utf8.encode(keyStr)));
    final iv = enc.IV(Uint8List.fromList(utf8.encode(ivStr)));
    final encrypter =
        enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
    final cipher = enc.Encrypted(_hexDecode(cipherHex));
    return encrypter.decrypt(cipher, iv: iv);
  }

  /// 同上,但 key/iv 是**原始字节的 hex**(非 UTF-8):适合二进制 key / 内嵌 IV。
  String _aesCbcDecryptHex(String cipherHex, String keyHex, String ivHex) {
    final key = enc.Key(_hexDecode(keyHex));
    final iv = enc.IV(_hexDecode(ivHex));
    final encrypter =
        enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
    return encrypter.decrypt(enc.Encrypted(_hexDecode(cipherHex)), iv: iv);
  }

  Uint8List _hexDecode(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i + 1 < hex.length; i += 2) {
      out[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return out;
  }

  String _hexEncode(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

const String _bootstrapJs = r'''
globalThis.host = globalThis.host || {};
globalThis.host.crypto = {
  _c: function () { return sendMessage('crypto', JSON.stringify(Array.prototype.slice.call(arguments))); },
  md5: function (s) { return this._c('md5', s); },
  hmacSha256: function (msg, key) { return this._c('hmacSha256', msg, key); },
  aesCbcDecrypt: function (cipherHex, key, iv) { return this._c('aesCbcDecrypt', cipherHex, key, iv); },
  aesCbcDecryptHex: function (cipherHex, keyHex, ivHex) { return this._c('aesCbcDecryptHex', cipherHex, keyHex, ivHex); },
  base64Decode: function (s) { return this._c('base64Decode', s); },
  base64Encode: function (s) { return this._c('base64Encode', s); },
  base64ToHex: function (s) { return this._c('base64ToHex', s); }
};
''';
