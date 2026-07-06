import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'js_engine.dart';

/// 把 Dart 的 HTML 解析(package:html)以 `host.html.*` 暴露给 JS 源。
///
/// 跨界策略:用**节点 id 表**。JS 传 selector,Dart 解析后回传数据或子节点 id;
/// 节点对象只留在 Dart 侧。选择器字符串可直接从参考项目的 cheerio 代码复用。
///
/// JS 侧 API(由 [_bootstrapJs] 注入):
/// ```js
/// var doc  = host.html.parse(htmlText);          // -> nodeId
/// var as   = host.html.select(doc, 'ul.list li a'); // -> [nodeId]
/// var a0   = host.html.selectFirst(doc, 'h1');   // -> nodeId | null
/// host.html.text(a0);                            // -> string
/// host.html.attr(a0, 'href');                    // -> string
/// host.html.outerHtml(a0);                       // -> string
/// ```
class HtmlHost {
  HtmlHost(JsEngine engine) {
    engine.onMessage('html', _handle);
    engine.evalSync(_bootstrapJs);
  }

  final Map<int, dom.Node> _nodes = {};
  int _next = 1;

  int _put(dom.Node n) {
    final id = _next++;
    _nodes[id] = n;
    return id;
  }

  dom.Element? _asElement(int id) {
    final n = _nodes[id];
    if (n is dom.Element) return n;
    if (n is dom.Document) return n.documentElement;
    return null;
  }

  /// 每次源方法调用结束后清空,避免节点表无限膨胀。
  void reset() {
    _nodes.clear();
    _next = 1;
  }

  // flutter_js 已把入站消息 JSON 解码(收到的是 List),并会把返回值 JSON 编码回 JS。
  // 所以这里直接用 List、直接返回原生对象,双方都不再手动 jsonEncode/Decode。
  Object? _handle(dynamic message) {
    final args = message as List;
    final op = args[0] as String;
    switch (op) {
      case 'parse':
        return _put(html_parser.parse(args[1] as String));
      case 'select':
        final scope = _asElement((args[1] as num).toInt());
        if (scope == null) return <int>[];
        final matched = scope.querySelectorAll(args[2] as String);
        return [for (final e in matched) _put(e)];
      case 'text':
        return _asElement((args[1] as num).toInt())?.text ?? '';
      case 'attr':
        return _asElement((args[1] as num).toInt())
                ?.attributes[args[2] as String] ??
            '';
      case 'html':
        return _asElement((args[1] as num).toInt())?.outerHtml ?? '';
      default:
        return null;
    }
  }
}

const String _bootstrapJs = r'''
globalThis.host = globalThis.host || {};
globalThis.host.html = {
  // flutter_js 把 Dart 返回值直接编组为原生 JS 值(number/array/string),无需 JSON.parse。
  // 入站仍用 JSON.stringify:flutter_js 会把它解码成 Dart List 交给 handler。
  _c: function (a) { return sendMessage('html', JSON.stringify(a)); },
  parse: function (html) { return this._c(['parse', html]); },
  select: function (node, sel) { return this._c(['select', node, sel]); },
  selectFirst: function (node, sel) {
    var r = this.select(node, sel);
    return r.length ? r[0] : null;
  },
  text: function (node) { return node == null ? '' : this._c(['text', node]); },
  attr: function (node, name) { return node == null ? '' : this._c(['attr', node, name]); },
  outerHtml: function (node) { return node == null ? '' : this._c(['html', node]); }
};
''';
