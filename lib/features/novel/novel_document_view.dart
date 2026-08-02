import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/novel_library_store.dart';
import '../../core/novel/models.dart';
import '../../core/novel/novel_document_sanitizer.dart';

enum NovelReaderCommand { previous, next, toggleControls }

abstract interface class NovelDocumentController {
  ValueChanged<NovelReaderCommand>? get onCommand;
  set onCommand(ValueChanged<NovelReaderCommand>? value);

  ValueChanged<NovelLocator>? get onLocatorChanged;
  set onLocatorChanged(ValueChanged<NovelLocator>? value);

  Future<void> loadChapter(
    String chapterId,
    NovelDocument document,
    NovelReaderPreferences preferences,
  );

  Future<NovelLocator> captureLocator();
  Future<void> restoreLocator(NovelLocator locator);
  Future<void> applyPreferences(NovelReaderPreferences preferences);
  Future<bool> nextPage();
  Future<bool> previousPage();
}

class WebNovelDocumentController implements NovelDocumentController {
  InAppWebViewController? _webView;
  String _chapterId = '';
  NovelDocument? _pendingDocument;
  NovelReaderPreferences _preferences = const NovelReaderPreferences();
  NovelLocator? _pendingRestore;
  bool _loaded = false;

  @override
  ValueChanged<NovelReaderCommand>? onCommand;

  @override
  ValueChanged<NovelLocator>? onLocatorChanged;

  Future<void> attach(InAppWebViewController controller) async {
    _webView = controller;
    controller.addJavaScriptHandler(
      handlerName: 'dmrCommand',
      callback: (arguments) {
        final value = arguments.isEmpty ? '' : arguments.first.toString();
        final command = switch (value) {
          'previous' => NovelReaderCommand.previous,
          'next' => NovelReaderCommand.next,
          _ => NovelReaderCommand.toggleControls,
        };
        onCommand?.call(command);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'dmrLocator',
      callback: (arguments) {
        if (arguments.isEmpty) return;
        final locator = _locatorFromValue(arguments.first, _chapterId);
        if (locator != null) onLocatorChanged?.call(locator);
      },
    );
    final document = _pendingDocument;
    if (document != null) {
      await _load(document);
    }
  }

  Future<void> onLoadStop() async {
    final webView = _webView;
    if (webView == null || _chapterId.isEmpty) return;
    final loadedChapter = await webView.evaluateJavascript(
      source: 'document.body?.dataset?.dmrChapter || ""',
    );
    if (loadedChapter?.toString() != _chapterId) return;
    await webView.evaluateJavascript(source: _bridgeScript);
    _loaded = true;
    await applyPreferences(_preferences);
    final restore = _pendingRestore;
    if (restore != null) {
      _pendingRestore = null;
      await restoreLocator(restore);
    }
  }

  @override
  Future<void> loadChapter(
    String chapterId,
    NovelDocument document,
    NovelReaderPreferences preferences,
  ) async {
    _chapterId = chapterId;
    _preferences = preferences;
    _pendingDocument = document;
    if (_webView != null) await _load(document);
  }

  Future<void> _load(NovelDocument document) async {
    final webView = _webView;
    if (webView == null) return;
    _loaded = false;
    final base = document.baseUrl;
    await webView.loadData(
      data: buildNovelReaderHtml(document, chapterId: _chapterId),
      baseUrl: base == null || base.isEmpty ? null : WebUri(base),
      mimeType: 'text/html',
      encoding: 'utf-8',
    );
  }

  @override
  Future<NovelLocator> captureLocator() async {
    final webView = _webView;
    if (webView == null || _chapterId.isEmpty || !_loaded) {
      return NovelLocator(chapterId: _chapterId);
    }
    final value = await webView.evaluateJavascript(
      source: 'window.__dmrCapture ? window.__dmrCapture() : null',
    );
    return _locatorFromValue(value, _chapterId) ??
        NovelLocator(chapterId: _chapterId);
  }

  @override
  Future<void> restoreLocator(NovelLocator locator) async {
    final webView = _webView;
    if (webView == null || !_loaded) {
      _pendingRestore = locator;
      return;
    }
    final payload = jsonEncode({
      'blockId': locator.blockId,
      'fraction': locator.fraction,
    });
    await webView.evaluateJavascript(
      source: 'window.__dmrRestore && window.__dmrRestore($payload)',
    );
  }

  @override
  Future<void> applyPreferences(NovelReaderPreferences preferences) async {
    _preferences = preferences;
    final webView = _webView;
    if (webView == null || !_loaded) return;
    final payload = jsonEncode({
      'mode': preferences.mode.name,
      'fontFamily': preferences.fontFamily,
      'fontSize': preferences.fontSize,
      'lineHeight': preferences.lineHeight,
      'paragraphSpacing': preferences.paragraphSpacing,
      'horizontalMargin': preferences.horizontalMargin,
      'theme': preferences.theme.name,
    });
    await webView.evaluateJavascript(
      source: 'window.__dmrApply && window.__dmrApply($payload)',
    );
  }

  @override
  Future<bool> nextPage() => _turn(1);

  @override
  Future<bool> previousPage() => _turn(-1);

  Future<bool> _turn(int direction) async {
    final webView = _webView;
    if (webView == null) return false;
    final value = await webView.evaluateJavascript(
      source: 'window.__dmrTurn ? window.__dmrTurn($direction) : false',
    );
    return value == true || value == 1 || value == 'true';
  }
}

class NovelDocumentView extends StatefulWidget {
  const NovelDocumentView({
    super.key,
    required this.controller,
  });

  final WebNovelDocumentController controller;

  @override
  State<NovelDocumentView> createState() => _NovelDocumentViewState();
}

class _NovelDocumentViewState extends State<NovelDocumentView> {
  static Future<WebViewEnvironment?>? _environmentFuture;

  Future<WebViewEnvironment?> _environment() {
    return _environmentFuture ??= _createEnvironment();
  }

  static Future<WebViewEnvironment?> _createEnvironment() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return null;
    final support = await getApplicationSupportDirectory();
    return WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: '${support.path}\\novel_webview2',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<WebViewEnvironment?>(
      future: _environment(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('${snapshot.error}'));
        }
        return InAppWebView(
          webViewEnvironment: snapshot.data,
          initialData: InAppWebViewInitialData(data: _htmlShell('')),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            supportZoom: false,
            disableContextMenu: true,
            transparentBackground: true,
            horizontalScrollBarEnabled: false,
            verticalScrollBarEnabled: false,
          ),
          onWebViewCreated: widget.controller.attach,
          onLoadStop: (_, __) => widget.controller.onLoadStop(),
          shouldOverrideUrlLoading: (_, __) async =>
              NavigationActionPolicy.CANCEL,
        );
      },
    );
  }
}

NovelLocator? _locatorFromValue(Object? value, String chapterId) {
  try {
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! Map) return null;
    final map = decoded.cast<String, dynamic>();
    return NovelLocator(
      chapterId: chapterId,
      blockId: map['blockId'] as String?,
      fraction: (map['fraction'] as num?)?.toDouble() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

String buildNovelReaderHtml(NovelDocument document, {String? chapterId}) {
  final base =
      document.baseUrl == null ? null : Uri.tryParse(document.baseUrl!);
  final String content;
  if (document.format == NovelDocumentFormat.html) {
    content = NovelDocumentSanitizer.sanitize(
      document.content,
      baseUrl: base,
    );
  } else {
    const escape = HtmlEscape(HtmlEscapeMode.element);
    final paragraphs = document.content.split(RegExp(r'\r?\n')).map((line) {
      return line.isEmpty ? '<p><br></p>' : '<p>${escape.convert(line)}</p>';
    }).join();
    content = NovelDocumentSanitizer.sanitize(paragraphs, baseUrl: base);
  }
  return _htmlShell(content, chapterId: chapterId);
}

/// 正文外壳。CSP 里 `img-src` 只给 `file:`/`data:` 是有意的:WebView 一律不碰
/// 网络(`connect-src 'none'`),远程图片由 [NovelDocumentCache] 在 Dart 侧下载后
/// 重写成本地相对路径,离线阅读才显示。
///
/// 因此 sanitizer 必须保留远程 `<img src>` —— 缓存层正是在 sanitize 之后的 HTML
/// 里扫描这些 URL 再做替换,提前剥掉会让离线图片全部丢失。在线阅读时这些 src
/// 会被 CSP 拦下不加载,这是预期行为,不是漏配。
String _htmlShell(String body, {String? chapterId}) {
  const escape = HtmlEscape(HtmlEscapeMode.attribute);
  final chapter = escape.convert(chapterId ?? '');
  return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; font-src file: data:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
<style id="dmr-style">html,body{margin:0;padding:0;background:#111;color:#eee}</style>
</head><body data-dmr-chapter="$chapter">$body</body></html>''';
}

const _bridgeScript = r'''
(() => {
  if (window.__dmrInstalled) return;
  window.__dmrInstalled = true;
  let mode = 'paged';
  let reportTimer = 0;
  const root = document.scrollingElement || document.documentElement;
  const blocks = () => [...document.querySelectorAll('[data-dmr-block]')];
  const metrics = () => mode === 'paged'
    ? {pos: root.scrollLeft, max: Math.max(0, root.scrollWidth - innerWidth)}
    : {pos: root.scrollTop, max: Math.max(0, root.scrollHeight - innerHeight)};
  const capture = () => {
    const block = blocks().find((el) => {
      const rect = el.getBoundingClientRect();
      return mode === 'paged'
        ? rect.right > 0 && rect.left < innerWidth
        : rect.bottom > 0 && rect.top < innerHeight;
    });
    const m = metrics();
    return JSON.stringify({
      blockId: block ? block.dataset.dmrBlock : null,
      fraction: m.max > 0 ? Math.max(0, Math.min(1, m.pos / m.max)) : 0,
      pageIndex: mode === 'paged' ? Math.round(m.pos / innerWidth) : 0,
      pageCount: mode === 'paged' ? Math.max(1, Math.ceil(root.scrollWidth / innerWidth)) : 1,
    });
  };
  const report = () => {
    clearTimeout(reportTimer);
    reportTimer = setTimeout(() => {
      window.flutter_inappwebview?.callHandler('dmrLocator', capture());
    }, 120);
  };
  window.__dmrCapture = capture;
  window.__dmrRestore = (locator) => {
    const block = locator.blockId
      ? document.querySelector(`[data-dmr-block="${CSS.escape(locator.blockId)}"]`)
      : null;
    if (block) block.scrollIntoView({block: 'start', inline: 'start'});
    else {
      const m = metrics();
      const target = Math.max(0, Math.min(1, Number(locator.fraction) || 0)) * m.max;
      if (mode === 'paged') root.scrollLeft = target;
      else root.scrollTop = target;
    }
    report();
  };
  window.__dmrApply = (p) => {
    mode = p.mode === 'scroll' ? 'scroll' : 'paged';
    document.documentElement.dataset.mode = mode;
    const colors = {
      dark: ['#17191c', '#e8e8e8'], black: ['#000', '#ddd'],
      white: ['#fff', '#202124'], sepia: ['#f3ead3', '#3e3427']
    }[p.theme] || ['#f3ead3', '#3e3427'];
    const family = String(p.fontFamily || '').replace(/["'\\]/g, '');
    document.getElementById('dmr-style').textContent = `
      *{box-sizing:border-box} html{background:${colors[0]};color:${colors[1]}}
      body{margin:0;padding:22px ${p.horizontalMargin}px;font-family:${family ? `'${family}',` : ''}serif;font-size:${p.fontSize}px;line-height:${p.lineHeight};background:${colors[0]};color:${colors[1]};letter-spacing:0;overflow-wrap:anywhere}
      p{margin:0 0 ${p.paragraphSpacing}px} img{max-width:100%;height:auto} a{color:inherit} ruby rt{font-size:.55em}
      html[data-mode=paged]{overflow:hidden} html[data-mode=paged] body{height:100vh;column-width:100vw;column-gap:0;column-fill:auto;overflow:visible}
      html[data-mode=scroll]{overflow-y:auto;overflow-x:hidden} html[data-mode=scroll] body{min-height:100vh}
    `;
  };
  window.__dmrTurn = (direction) => {
    const m = metrics();
    if (mode === 'paged') {
      const target = root.scrollLeft + direction * innerWidth;
      if (target < -1 || target > m.max + 1) return false;
      root.scrollTo({left: Math.max(0, Math.min(m.max, target)), behavior:'smooth'});
    } else {
      const step = innerHeight * .88;
      const target = root.scrollTop + direction * step;
      if (target < -1 || target > m.max + 1) return false;
      root.scrollTo({top: Math.max(0, Math.min(m.max, target)), behavior:'smooth'});
    }
    report();
    return true;
  };
  document.addEventListener('click', (event) => {
    const anchor = event.target.closest?.('a[href]');
    if (anchor) {
      event.preventDefault();
      const href = anchor.getAttribute('href') || '';
      if (href.startsWith('#')) document.getElementById(href.slice(1))?.scrollIntoView();
      return;
    }
    const ratio = event.clientX / innerWidth;
    const command = ratio < .25 ? 'previous' : ratio > .75 ? 'next' : 'toggle';
    window.flutter_inappwebview?.callHandler('dmrCommand', command);
  });
  let touchX = 0, touchY = 0;
  document.addEventListener('touchstart', (event) => {
    touchX = event.changedTouches[0].clientX; touchY = event.changedTouches[0].clientY;
  }, {passive:true});
  document.addEventListener('touchend', (event) => {
    if (mode !== 'paged') return;
    const dx = event.changedTouches[0].clientX - touchX;
    const dy = event.changedTouches[0].clientY - touchY;
    if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) {
      window.flutter_inappwebview?.callHandler('dmrCommand', dx < 0 ? 'next' : 'previous');
    }
  }, {passive:true});
  addEventListener('scroll', report, {passive:true});
  addEventListener('resize', report);
})();
''';
