import 'package:lzstring/lzstring.dart';

import 'js_engine.dart';

/// 把 lz-string(sync)以 `host.lz.*` 暴露给 JS 源。
/// 部分源的章节页表用 LZString 压缩,解包时用到。
///
/// ```js
/// var json = host.lz.decompressFromBase64(payload);
/// ```
class LzHost {
  LzHost(JsEngine engine) {
    engine.onMessage('lz', _handle);
    engine.evalSync(_bootstrapJs);
  }

  Object? _handle(dynamic message) {
    final args = message as List;
    final op = args[0] as String;
    final input = args.length > 1 ? args[1] as String? : null;
    switch (op) {
      case 'fromBase64':
        return LZString.decompressFromBase64Sync(input) ?? '';
      case 'fromEncodedURIComponent':
        return LZString.decompressFromEncodedURIComponentSync(input) ?? '';
      case 'decompress':
        return LZString.decompressSync(input) ?? '';
      default:
        return null;
    }
  }
}

const String _bootstrapJs = r'''
globalThis.host = globalThis.host || {};
globalThis.host.lz = {
  _c: function (op, s) { return sendMessage('lz', JSON.stringify([op, s])); },
  decompressFromBase64: function (s) { return this._c('fromBase64', s); },
  decompressFromEncodedURIComponent: function (s) { return this._c('fromEncodedURIComponent', s); },
  decompress: function (s) { return this._c('decompress', s); }
};
''';
