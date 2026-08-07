import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/novel_library_store.dart';
import '../../core/novel/models.dart';
import '../../core/novel/novel_document_sanitizer.dart';
import '../../core/novel/reader/novel_background_store.dart';
import '../../core/novel/reader/novel_font_store.dart';
import '../../core/novel/reader/novel_reader_data.dart';
import '../../core/novel/reader/novel_reader_models.dart';
import '../../core/novel/reader/novel_reader_theme.dart';

export '../../core/novel/reader/novel_reader_models.dart'
    show NovelReaderCommand;

abstract interface class NovelDocumentController {
  ValueChanged<NovelReaderCommand>? get onCommand;
  set onCommand(ValueChanged<NovelReaderCommand>? value);

  ValueChanged<NovelLocator>? get onLocatorChanged;
  set onLocatorChanged(ValueChanged<NovelLocator>? value);

  ValueChanged<NovelSelection?>? get onSelectionChanged;
  set onSelectionChanged(ValueChanged<NovelSelection?>? value);

  ValueChanged<bool>? get onCaptureStateChanged;
  set onCaptureStateChanged(ValueChanged<bool>? value);

  ValueChanged<Set<String>>? get onUnresolvedAnnotationsChanged;
  set onUnresolvedAnnotationsChanged(ValueChanged<Set<String>>? value);

  Future<void> loadChapter(
    String chapterId,
    NovelDocument document,
    NovelReaderPreferences preferences,
  );

  Future<NovelLocator> captureLocator();
  Future<NovelPageMetrics> pageMetrics();
  Future<NovelPageFrame?> capturePage(int pageIndex);
  Future<void> showPage(int pageIndex);
  Future<void> restoreLocator(NovelLocator locator);
  Future<void> applyPreferences(NovelReaderPreferences preferences);
  Future<Set<String>> applyAnnotations(Iterable<NovelAnnotation> annotations);
  Future<void> clearSelection();
  Future<bool> nextPage();
  Future<bool> previousPage();
}

class WebNovelDocumentController implements NovelDocumentController {
  WebNovelDocumentController({
    NovelFontStore? fontStore,
    NovelBackgroundStore? backgroundStore,
  })  : _fontStore = fontStore ?? NovelFontStore(),
        _backgroundStore = backgroundStore ?? NovelBackgroundStore();

  final NovelFontStore _fontStore;
  final NovelBackgroundStore _backgroundStore;
  InAppWebViewController? _webView;
  String _chapterId = '';
  NovelDocument? _pendingDocument;
  NovelReaderPreferences _preferences = const NovelReaderPreferences();
  NovelLocator? _pendingRestore;
  List<NovelAnnotation> _pendingAnnotations = const [];
  Future<void> _annotationApplication = Future.value();
  bool _loaded = false;
  String _appliedFontId = NovelFontIds.notoSerifSc;

  ValueChanged<String>? onRecoverableError;
  ValueChanged<String>? onFontFallback;
  VoidCallback? onBackgroundFallback;

  @override
  ValueChanged<NovelReaderCommand>? onCommand;

  @override
  ValueChanged<NovelLocator>? onLocatorChanged;

  @override
  ValueChanged<NovelSelection?>? onSelectionChanged;

  @override
  ValueChanged<bool>? onCaptureStateChanged;

  @override
  ValueChanged<Set<String>>? onUnresolvedAnnotationsChanged;

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
        final locator = parseNovelLocatorValue(
          arguments.first,
          chapterId: _chapterId,
        );
        if (locator != null) onLocatorChanged?.call(locator);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'dmrSelection',
      callback: (arguments) {
        if (arguments.isEmpty) {
          onSelectionChanged?.call(null);
          return;
        }
        onSelectionChanged?.call(
          parseNovelSelectionValue(arguments.first, chapterId: _chapterId),
        );
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
    await webView.evaluateJavascript(source: novelReaderBridgeScript);
    await webView.evaluateJavascript(
      source: 'window.__dmrExternalInput = true',
    );
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
      source: 'window.__dmrCaptureAnchor ? '
          'window.__dmrCaptureAnchor() : '
          '(window.__dmrCapture ? window.__dmrCapture() : null)',
    );
    return parseNovelLocatorValue(value, chapterId: _chapterId) ??
        NovelLocator(chapterId: _chapterId);
  }

  @override
  Future<NovelPageMetrics> pageMetrics() async {
    final webView = _webView;
    if (webView == null || !_loaded) return _emptyPageMetrics;
    final value = await webView.evaluateJavascript(
      source: 'window.__dmrMetrics ? '
          'JSON.stringify(window.__dmrMetrics()) : null',
    );
    return parseNovelPageMetrics(value) ?? _emptyPageMetrics;
  }

  @override
  Future<NovelPageFrame?> capturePage(int pageIndex) async {
    final webView = _webView;
    if (webView == null || !_loaded || _chapterId.isEmpty) return null;
    await _annotationApplication;
    final original = await pageMetrics();
    final target = clampNovelPageIndex(pageIndex, original.pageCount);
    onCaptureStateChanged?.call(true);
    try {
      await showPage(target);
      await _waitForPagePaint(webView);
      final bytes = await webView.takeScreenshot();
      if (bytes == null || bytes.isEmpty) return null;
      return NovelPageFrame(
        key: NovelPageKey(
          chapterId: _chapterId,
          pageIndex: target,
          layoutFingerprint: original.layoutFingerprint,
        ),
        viewport: original.viewport,
        bytes: bytes,
      );
    } finally {
      try {
        await showPage(original.currentPageIndex);
        await _waitForPagePaint(webView);
      } finally {
        onCaptureStateChanged?.call(false);
      }
    }
  }

  @override
  Future<void> showPage(int pageIndex) async {
    final webView = _webView;
    if (webView == null || !_loaded) return;
    await webView.evaluateJavascript(
      source: 'window.__dmrShowPage && window.__dmrShowPage($pageIndex)',
    );
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
      'charOffset': locator.charOffset,
      'quote': locator.quote,
      'prefix': locator.prefix,
      'suffix': locator.suffix,
      'fraction': locator.fraction,
    });
    await webView.evaluateJavascript(
      source: 'window.__dmrRestoreAnchor ? '
          'window.__dmrRestoreAnchor($payload) : '
          '(window.__dmrRestore && window.__dmrRestore($payload))',
    );
  }

  @override
  Future<void> applyPreferences(NovelReaderPreferences preferences) async {
    final requestedId = normalizeNovelFontId(preferences.fontFamily);
    final font = await _fontStore.resolveForUse(requestedId);
    var applied = preferences.copyWith(fontFamily: font.id);
    if (font.id != requestedId) {
      onFontFallback?.call(font.id);
      onRecoverableError?.call('所选字体文件已不可用，已恢复内置字体。');
    }
    NovelBackgroundRecord? background;
    final requestedBackground = applied.backgroundAssetId;
    if (requestedBackground != null) {
      background = await _backgroundStore.resolve(requestedBackground);
      if (background == null) {
        applied = applied.copyWith(clearBackgroundAsset: true);
        onBackgroundFallback?.call();
        onRecoverableError?.call('背景图片已不可用，已恢复主题底色。');
      }
    } else if (applied.theme == NovelReaderTheme.paper) {
      background = await _backgroundStore.paperTexture(seed: 20260807);
    }
    _preferences = applied;
    final webView = _webView;
    if (webView == null || !_loaded) return;
    final previous = _preferences.copyWith(fontFamily: _appliedFontId);
    await _applyPreferencesToWebView(webView, applied, font, background);
    final metrics = await pageMetrics();
    if (font.id != _appliedFontId &&
        (metrics.fontLoadFailed || metrics.visibleTextLength == 0)) {
      final previousFont = await _fontStore.resolveForUse(_appliedFontId);
      applied = previous.copyWith(fontFamily: previousFont.id);
      await _applyPreferencesToWebView(
        webView,
        applied,
        previousFont,
        background,
      );
      _preferences = applied;
      onFontFallback?.call(previousFont.id);
      onRecoverableError?.call('字体加载后正文不可见，已恢复上一字体。');
      return;
    }
    _appliedFontId = font.id;
    await applyAnnotations(_pendingAnnotations);
  }

  @override
  Future<Set<String>> applyAnnotations(
    Iterable<NovelAnnotation> annotations,
  ) async {
    _pendingAnnotations = annotations
        .where(
          (value) =>
              !value.isDeleted && value.range.start.chapterId == _chapterId,
        )
        .toList(growable: false);
    final webView = _webView;
    if (webView == null || !_loaded) return const {};
    final payload = jsonEncode([
      for (final annotation in _pendingAnnotations)
        {
          'id': annotation.id,
          'colorId': annotation.colorId,
          'quote': annotation.range.quote,
          'start': annotation.range.start.toJson(),
          'end': annotation.range.end.toJson(),
        },
    ]);
    Set<String> unresolved = const {};
    final operation = () async {
      try {
        final value = await webView.evaluateJavascript(
          source: 'window.__dmrApplyAnnotations ? '
              'JSON.stringify(window.__dmrApplyAnnotations($payload)) : "[]"',
        );
        final decoded = _decodeBridgeValue(value);
        if (decoded is List) {
          unresolved = decoded.map((item) => item.toString()).toSet();
        }
      } catch (_) {
        unresolved = _pendingAnnotations.map((value) => value.id).toSet();
      }
      onUnresolvedAnnotationsChanged?.call(unresolved);
    }();
    _annotationApplication = operation;
    await operation;
    return unresolved;
  }

  @override
  Future<void> clearSelection() async {
    final webView = _webView;
    if (webView != null && _loaded) {
      await webView.evaluateJavascript(
        source: 'window.__dmrClearSelection && window.__dmrClearSelection()',
      );
    }
    onSelectionChanged?.call(null);
  }

  Future<void> _applyPreferencesToWebView(
    InAppWebViewController webView,
    NovelReaderPreferences preferences,
    NovelFontRecord font,
    NovelBackgroundRecord? background,
  ) async {
    final baseProfile = novelReaderThemeProfile(preferences.theme);
    final profile = novelReaderThemeProfile(
      preferences.theme,
      foregroundOverrideArgb: preferences.foregroundArgb,
      readabilityBackgroundArgb: background == null
          ? null
          : blendNovelReaderArgb(
              baseProfile.backgroundArgb,
              background.averageArgb,
              preferences.textureStrength,
            ),
    );
    final payload = jsonEncode({
      'mode': preferences.mode.name,
      'fontFamily': font.cssFamily,
      'fontFaceCss': buildNovelFontFaceCss(font),
      'fontSize': preferences.fontSize,
      'lineHeight': preferences.lineHeight,
      'paragraphSpacing': preferences.paragraphSpacing,
      'horizontalMargin': preferences.horizontalMargin,
      'topMargin': preferences.topMargin,
      'bottomMargin': preferences.bottomMargin,
      'firstLineIndent': preferences.firstLineIndent,
      'textAlignment': preferences.textAlignment.name,
      'brightness': preferences.brightness,
      'theme': preferences.theme.name,
      'backgroundColor': cssColorFromArgb(profile.backgroundArgb),
      'foregroundColor': cssColorFromArgb(profile.foregroundArgb),
      'backgroundAssetId': preferences.backgroundAssetId ?? '',
      'backgroundFit': preferences.backgroundFit.name,
      'textureStrength': preferences.textureStrength,
      'backgroundCss': background == null
          ? ''
          : buildNovelBackgroundCss(
              uri: background.file.uri,
              fit: preferences.backgroundFit,
              strength: preferences.textureStrength,
            ),
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

  static Future<void> _waitForPagePaint(
    InAppWebViewController webView,
  ) async {
    await webView.evaluateJavascript(
      source: 'new Promise((resolve) => requestAnimationFrame(() => '
          'requestAnimationFrame(resolve)))',
    );
  }
}

const _emptyPageMetrics = NovelPageMetrics(
  pageCount: 1,
  currentPageIndex: 0,
  viewport: NovelViewport(width: 0, height: 0),
  layoutFingerprint: '',
);

class NovelDocumentView extends StatefulWidget {
  const NovelDocumentView({
    super.key,
    required this.controller,
  });

  final WebNovelDocumentController controller;

  @override
  State<NovelDocumentView> createState() => _NovelDocumentViewState();
}

InAppWebViewSettings buildNovelDocumentWebViewSettings() =>
    InAppWebViewSettings(
      javaScriptEnabled: true,
      useShouldOverrideUrlLoading: true,
      supportZoom: false,
      disableContextMenu: true,
      transparentBackground: true,
      horizontalScrollBarEnabled: false,
      verticalScrollBarEnabled: false,
      allowFileAccess: true,
      allowFileAccessFromFileURLs: true,
    );

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
          initialSettings: buildNovelDocumentWebViewSettings(),
          onWebViewCreated: widget.controller.attach,
          onLoadStop: (_, __) => widget.controller.onLoadStop(),
          shouldOverrideUrlLoading: (_, __) async =>
              NavigationActionPolicy.CANCEL,
        );
      },
    );
  }
}

int clampNovelPageIndex(int pageIndex, int pageCount) {
  if (pageCount <= 0 || pageIndex <= 0) return 0;
  final lastPage = pageCount - 1;
  return pageIndex > lastPage ? lastPage : pageIndex;
}

NovelPageMetrics? parseNovelPageMetrics(Object? value) {
  try {
    final decoded = _decodeBridgeValue(value);
    if (decoded is! Map) return null;
    final map = decoded.cast<String, dynamic>();
    final rawPageCount = (map['pageCount'] as num?)?.toInt() ?? 1;
    final pageCount = rawPageCount > 0 ? rawPageCount : 1;
    final rawPageIndex = (map['currentPageIndex'] as num?)?.toInt() ?? 0;
    final width = _finiteDouble(map['viewportWidth']) ?? 0;
    final height = _finiteDouble(map['viewportHeight']) ?? 0;
    final pixelRatio = _finiteDouble(map['devicePixelRatio']) ?? 1;
    return NovelPageMetrics(
      pageCount: pageCount,
      currentPageIndex: clampNovelPageIndex(rawPageIndex, pageCount),
      viewport: NovelViewport(
        width: width < 0 ? 0 : width,
        height: height < 0 ? 0 : height,
        devicePixelRatio: pixelRatio <= 0 ? 1 : pixelRatio,
      ),
      layoutFingerprint: map['layoutFingerprint']?.toString() ?? '',
      visibleTextLength:
          ((map['visibleTextLength'] as num?)?.toInt() ?? 0).clamp(0, 1 << 31),
      fontLoadFailed: map['fontLoadFailed'] == true,
    );
  } catch (_) {
    return null;
  }
}

NovelLocator? parseNovelLocatorValue(
  Object? value, {
  required String chapterId,
}) {
  try {
    final decoded = _decodeBridgeValue(value);
    if (decoded is! Map) return null;
    final map = decoded.cast<String, dynamic>();
    final rawOffset = (map['charOffset'] as num?)?.toInt();
    return NovelLocator(
      chapterId: chapterId,
      blockId: map['blockId'] as String?,
      charOffset: rawOffset == null || rawOffset < 0 ? null : rawOffset,
      quote: _boundedContext(map['quote'], keepTail: false),
      prefix: _boundedContext(map['prefix'], keepTail: true),
      suffix: _boundedContext(map['suffix'], keepTail: false),
      fraction: (map['fraction'] as num?)?.toDouble() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

NovelSelection? parseNovelSelectionValue(
  Object? value, {
  required String chapterId,
}) {
  try {
    final decoded = _decodeBridgeValue(value);
    if (decoded is! Map) return null;
    final map = decoded.cast<String, dynamic>();
    final text = map['text']?.toString() ?? '';
    if (text.isEmpty) return null;
    final start = parseNovelLocatorValue(
      map['start'],
      chapterId: chapterId,
    );
    final end = parseNovelLocatorValue(map['end'], chapterId: chapterId);
    if (start == null || end == null) return null;
    NovelSelectionRect? rect;
    final rawRect = map['rect'];
    if (rawRect is Map) {
      final values = rawRect.cast<String, dynamic>();
      final left = _finiteDouble(values['left']);
      final top = _finiteDouble(values['top']);
      final width = _finiteDouble(values['width']);
      final height = _finiteDouble(values['height']);
      if (left != null && top != null && width != null && height != null) {
        rect = NovelSelectionRect(left, top, width, height);
      }
    }
    return NovelSelection(text: text, start: start, end: end, rect: rect);
  } catch (_) {
    return null;
  }
}

Object? _decodeBridgeValue(Object? value) {
  if (value is String) return jsonDecode(value);
  return value;
}

double? _finiteDouble(Object? value) {
  final result = value is num ? value.toDouble() : null;
  return result != null && result.isFinite ? result : null;
}

String? _boundedContext(Object? value, {required bool keepTail}) {
  if (value == null) return null;
  final text = value.toString();
  if (text.isEmpty) return null;
  if (text.length <= 32) return text;
  return keepTail ? text.substring(text.length - 32) : text.substring(0, 32);
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

const novelReaderBridgeScript = r'''
(() => {
  if (window.__dmrInstalled) return;
  window.__dmrInstalled = true;
  let mode = 'paged';
  let reportTimer = 0;
  let fontLoadFailed = false;
  const root = document.scrollingElement || document.documentElement;
  const blocks = () => [...document.querySelectorAll('[data-dmr-block]')];
  const scrollMetrics = () => mode === 'paged'
    ? {pos: root.scrollLeft, max: Math.max(0, root.scrollWidth - innerWidth)}
    : {pos: root.scrollTop, max: Math.max(0, root.scrollHeight - innerHeight)};
  const pageCount = () => mode === 'paged'
    ? Math.max(1, Math.ceil(root.scrollWidth / Math.max(1, innerWidth)))
    : 1;
  const clampPage = (value) => Math.max(
    0,
    Math.min(pageCount() - 1, Math.trunc(Number(value) || 0))
  );
  const layoutFingerprint = () => document.body?.dataset?.dmrLayout || [
    mode, innerWidth, innerHeight, devicePixelRatio || 1,
    root.scrollWidth, root.scrollHeight
  ].join('|');
  const pageMetrics = () => ({
    pageCount: pageCount(),
    currentPageIndex: mode === 'paged'
      ? clampPage(Math.round(root.scrollLeft / Math.max(1, innerWidth)))
      : 0,
    viewportWidth: innerWidth,
    viewportHeight: innerHeight,
    devicePixelRatio: devicePixelRatio || 1,
    layoutFingerprint: layoutFingerprint(),
    visibleTextLength: [...document.querySelectorAll('[data-dmr-block]')]
      .filter((el) => {
        const rect = el.getBoundingClientRect();
        return rect.right > 0 && rect.left < innerWidth &&
          rect.bottom > 0 && rect.top < innerHeight;
      })
      .reduce((total, el) => total + String(el.textContent || '').trim().length, 0),
    fontLoadFailed
  });
  const textNodes = (block) => {
    const nodes = [];
    const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  };
  const offsetWithin = (block, node, offset) => {
    try {
      const range = document.createRange();
      range.setStart(block, 0);
      range.setEnd(node, Math.max(0, offset));
      return range.toString().length;
    } catch (_) {
      return 0;
    }
  };
  const anchorForPoint = (block, node, offset) => {
    if (!block) return null;
    const text = block.textContent || '';
    const charOffset = Math.max(
      0,
      Math.min(text.length, offsetWithin(block, node || block, offset || 0))
    );
    return {
      blockId: block.dataset.dmrBlock || null,
      charOffset,
      quote: text.slice(charOffset, charOffset + 32),
      prefix: text.slice(Math.max(0, charOffset - 32), charOffset),
      suffix: text.slice(charOffset + 32, charOffset + 64)
    };
  };
  const visibleBlock = () => blocks().find((el) => {
    const rect = el.getBoundingClientRect();
    return mode === 'paged'
      ? rect.right > 0 && rect.left < innerWidth
      : rect.bottom > 0 && rect.top < innerHeight;
  });
  const captureAnchor = () => {
    const block = visibleBlock();
    const rect = block?.getBoundingClientRect();
    const x = Math.max(1, Math.min(innerWidth - 1, (rect?.left || 0) + 1));
    const y = Math.max(1, Math.min(innerHeight - 1, (rect?.top || 0) + 1));
    const caret = document.caretPositionFromPoint?.(x, y);
    const legacyRange = caret ? null : document.caretRangeFromPoint?.(x, y);
    const anchor = anchorForPoint(
      block,
      caret?.offsetNode || legacyRange?.startContainer,
      caret?.offset ?? legacyRange?.startOffset ?? 0
    ) || {};
    const m = scrollMetrics();
    const paging = pageMetrics();
    return JSON.stringify({
      ...anchor,
      fraction: m.max > 0 ? Math.max(0, Math.min(1, m.pos / m.max)) : 0,
      pageIndex: paging.currentPageIndex,
      pageCount: paging.pageCount
    });
  };
  const resolveAnchor = (locator) => {
    let block = locator.blockId
      ? document.querySelector(`[data-dmr-block="${CSS.escape(locator.blockId)}"]`)
      : null;
    let charOffset = Math.max(0, Number(locator.charOffset) || 0);
    if (!block && locator.quote) {
      for (const candidate of blocks()) {
        const text = candidate.textContent || '';
        const index = text.indexOf(String(locator.quote));
        if (index < 0) continue;
        const prefix = String(locator.prefix || '');
        const suffix = String(locator.suffix || '');
        const before = text.slice(Math.max(0, index - prefix.length), index);
        const after = text.slice(
          index + String(locator.quote).length,
          index + String(locator.quote).length + suffix.length
        );
        if ((!prefix || before.endsWith(prefix)) && (!suffix || after.startsWith(suffix))) {
          block = candidate;
          charOffset = index;
          break;
        }
      }
    }
    return block ? {block, charOffset} : null;
  };
  const scrollToAnchor = (resolved) => {
    const nodes = textNodes(resolved.block);
    let remaining = resolved.charOffset;
    let node = nodes[0] || resolved.block;
    let offset = 0;
    for (const candidate of nodes) {
      const length = candidate.textContent?.length || 0;
      node = candidate;
      offset = length;
      if (remaining <= length) {
        offset = remaining;
        break;
      }
      remaining -= length;
    }
    try {
      const range = document.createRange();
      range.setStart(node, Math.min(offset, node.textContent?.length || 0));
      range.collapse(true);
      node.parentElement?.scrollIntoView({block: 'start', inline: 'start'});
      return range;
    } catch (_) {
      resolved.block.scrollIntoView({block: 'start', inline: 'start'});
      return null;
    }
  };
  const restoreAnchor = (locator) => {
    const resolved = resolveAnchor(locator || {});
    if (resolved) scrollToAnchor(resolved);
    else {
      const m = scrollMetrics();
      const target = Math.max(0, Math.min(1, Number(locator?.fraction) || 0)) * m.max;
      if (mode === 'paged') root.scrollLeft = target;
      else root.scrollTop = target;
    }
    report();
  };
  const selectionAnchor = (node, offset) => {
    const element = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
    const block = element?.closest?.('[data-dmr-block]');
    return anchorForPoint(block, node, offset);
  };
  const captureSelection = () => {
    const selection = getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;
    const range = selection.getRangeAt(0);
    const start = selectionAnchor(range.startContainer, range.startOffset);
    const end = selectionAnchor(range.endContainer, range.endOffset);
    if (!start || !end) return null;
    const endElement = range.endContainer?.nodeType === Node.ELEMENT_NODE
      ? range.endContainer
      : range.endContainer?.parentElement;
    const endBlock = endElement?.closest?.('[data-dmr-block]');
    const endText = endBlock?.textContent || '';
    end.suffix = endText.slice(end.charOffset, end.charOffset + 32);
    const rect = range.getBoundingClientRect();
    return {
      text: String(selection).slice(0, 4096),
      start,
      end,
      rect: {
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height
      }
    };
  };
  const pointAtOffset = (block, rawOffset) => {
    let remaining = Math.max(0, Number(rawOffset) || 0);
    const nodes = textNodes(block);
    for (const node of nodes) {
      const length = node.textContent?.length || 0;
      if (remaining <= length) return {node, offset: remaining};
      remaining -= length;
    }
    const node = nodes.at(-1) || block;
    return {node, offset: node.textContent?.length || 0};
  };
  const rangeFromOffsets = (startBlock, startOffset, endBlock, endOffset) => {
    try {
      const start = pointAtOffset(startBlock, startOffset);
      const end = pointAtOffset(endBlock, endOffset);
      const range = document.createRange();
      range.setStart(start.node, start.offset);
      range.setEnd(end.node, end.offset);
      return range.collapsed ? null : range;
    } catch (_) {
      return null;
    }
  };
  const directRange = (annotation) => {
    const start = annotation.start || {};
    const end = annotation.end || {};
    const startBlock = start.blockId
      ? document.querySelector(`[data-dmr-block="${CSS.escape(start.blockId)}"]`)
      : null;
    const endBlock = end.blockId
      ? document.querySelector(`[data-dmr-block="${CSS.escape(end.blockId)}"]`)
      : null;
    if (!startBlock || !endBlock) return null;
    const range = rangeFromOffsets(
      startBlock,
      start.charOffset,
      endBlock,
      end.charOffset
    );
    if (!range) return null;
    const quote = String(annotation.quote || '');
    return !quote || range.toString().slice(0, quote.length) === quote
      ? range
      : null;
  };
  const quoteRange = (annotation) => {
    const quote = String(annotation.quote || '');
    if (!quote) return null;
    const prefix = String(annotation.start?.prefix || '');
    const suffix = String(annotation.end?.suffix || '');
    for (const block of blocks()) {
      const text = block.textContent || '';
      let from = 0;
      while (from <= text.length) {
        const index = text.indexOf(quote, from);
        if (index < 0) break;
        const before = text.slice(Math.max(0, index - prefix.length), index);
        const after = text.slice(index + quote.length, index + quote.length + suffix.length);
        if ((!prefix || before.endsWith(prefix)) && (!suffix || after.startsWith(suffix))) {
          return rangeFromOffsets(block, index, block, index + quote.length);
        }
        from = index + 1;
      }
    }
    return null;
  };
  const resolveStoredRange = (annotation) =>
    directRange(annotation) || quoteRange(annotation);
  window.__dmrApplyAnnotations = (annotations) => {
    const values = Array.isArray(annotations) ? annotations : [];
    const unresolved = [];
    if (!globalThis.Highlight || !CSS?.highlights) {
      return values.map((value) => String(value.id || ''));
    }
    for (const name of ['yellow', 'green', 'blue', 'pink']) {
      CSS.highlights.delete(`dmr-${name}`);
    }
    const grouped = {yellow: [], green: [], blue: [], pink: []};
    for (const annotation of values) {
      const range = resolveStoredRange(annotation);
      if (!range) {
        unresolved.push(String(annotation.id || ''));
        continue;
      }
      const color = Object.hasOwn(grouped, annotation.colorId)
        ? annotation.colorId
        : 'yellow';
      grouped[color].push(range);
    }
    for (const [color, ranges] of Object.entries(grouped)) {
      if (ranges.length) CSS.highlights.set(`dmr-${color}`, new Highlight(...ranges));
    }
    return unresolved;
  };
  window.__dmrClearSelection = () => getSelection()?.removeAllRanges();
  window.__dmrMetrics = pageMetrics;
  window.__dmrShowPage = (pageIndex) => {
    if (mode !== 'paged') return 0;
    const target = clampPage(pageIndex);
    root.scrollLeft = Math.min(
      Math.max(0, root.scrollWidth - innerWidth),
      target * innerWidth
    );
    return target;
  };
  window.__dmrCaptureAnchor = captureAnchor;
  window.__dmrRestoreAnchor = restoreAnchor;
  window.__dmrSelection = captureSelection;
  window.__dmrCapture = captureAnchor;
  window.__dmrRestore = restoreAnchor;
  const report = () => {
    clearTimeout(reportTimer);
    reportTimer = setTimeout(() => {
      window.flutter_inappwebview?.callHandler('dmrLocator', captureAnchor());
    }, 120);
  };
  window.__dmrApply = async (p) => {
    mode = p.mode === 'scroll' ? 'scroll' : 'paged';
    document.documentElement.dataset.mode = mode;
    document.body.dataset.dmrLayout = JSON.stringify([
      mode,
      p.fontFamily || '',
      Number(p.fontSize) || 0,
      Number(p.lineHeight) || 0,
      Number(p.paragraphSpacing) || 0,
      Number(p.horizontalMargin) || 0,
      Number(p.topMargin) || 0,
      Number(p.bottomMargin) || 0,
      Number(p.firstLineIndent) || 0,
      p.textAlignment || '',
      Number(p.brightness) || 1,
      p.theme || '',
      p.backgroundAssetId || '',
      p.backgroundFit || '',
      Number(p.textureStrength) || 0,
      p.foregroundColor || '',
      innerWidth,
      innerHeight,
      devicePixelRatio || 1
    ]);
    const colors = [
      String(p.backgroundColor || '#dfe8cf'),
      String(p.foregroundColor || '#202124')
    ];
    const family = String(p.fontFamily || '').replace(/["'\\]/g, '');
    document.getElementById('dmr-style').textContent = `
      ${String(p.fontFaceCss || '')}
      ${String(p.backgroundCss || '')}
      *{box-sizing:border-box} html{background:${colors[0]};color:${colors[1]}}
      body{--dmr-side:max(${p.horizontalMargin}px, calc((100vw - 760px) / 2));margin:0;padding:${p.topMargin}px var(--dmr-side) ${p.bottomMargin}px;font-family:${family ? `'${family}',` : ''}serif;font-size:${p.fontSize}px;line-height:${p.lineHeight};background:${colors[0]};color:${colors[1]};letter-spacing:0;overflow-wrap:anywhere;filter:brightness(${p.brightness})}
      p{margin:0 0 ${p.paragraphSpacing}px;text-indent:${p.firstLineIndent}em;text-align:${p.textAlignment === 'justify' ? 'justify' : 'start'}} img{max-width:100%;height:auto} a{color:inherit} ruby rt{font-size:.55em}
      ::highlight(dmr-yellow){background:rgba(255,214,64,.52)} ::highlight(dmr-green){background:rgba(91,190,120,.46)} ::highlight(dmr-blue){background:rgba(77,154,235,.42)} ::highlight(dmr-pink){background:rgba(230,100,155,.42)}
      html[data-mode=paged]{overflow:hidden} html[data-mode=paged] body{height:100vh;column-width:calc(100vw - var(--dmr-side) - var(--dmr-side));column-gap:calc(var(--dmr-side) + var(--dmr-side));column-fill:auto;overflow:visible}
      html[data-mode=scroll]{overflow-y:auto;overflow-x:hidden} html[data-mode=scroll] body{min-height:100vh}
    `;
    fontLoadFailed = false;
    if (family && document.fonts?.load) {
      try {
        const loadedFaces = await document.fonts.load(`1em "${family}"`);
        fontLoadFailed = loadedFaces.length === 0;
      } catch (_) {
        fontLoadFailed = true;
      }
    }
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    return pageMetrics();
  };
  window.__dmrTurn = (direction) => {
    const m = scrollMetrics();
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
  let selectionTimer = 0;
  document.addEventListener('selectionchange', () => {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      const selection = captureSelection();
      window.flutter_inappwebview?.callHandler(
        'dmrSelection',
        selection ? JSON.stringify(selection) : null
      );
    }, 80);
  });
  const isInteractiveTarget = (target) => Boolean(
    target?.closest?.('a,button,input,textarea,select,[contenteditable]')
  );
  document.addEventListener('click', (event) => {
    const anchor = event.target.closest?.('a[href]');
    if (anchor) {
      event.preventDefault();
      const href = anchor.getAttribute('href') || '';
      if (href.startsWith('#')) document.getElementById(href.slice(1))?.scrollIntoView();
      return;
    }
    if (window.__dmrExternalInput) return;
    if (isInteractiveTarget(event.target)) return;
    const ratio = event.clientX / innerWidth;
    const command = ratio < .25 ? 'previous' : ratio > .75 ? 'next' : 'toggle';
    window.flutter_inappwebview?.callHandler('dmrCommand', command);
  });
  let lastWheelTurn = 0;
  document.addEventListener('wheel', (event) => {
    if (window.__dmrExternalInput) return;
    if (isInteractiveTarget(event.target)) return;
    if (mode !== 'paged' || Math.abs(event.deltaY) < 12) return;
    event.preventDefault();
    const now = Date.now();
    if (now - lastWheelTurn < 250) return;
    lastWheelTurn = now;
    window.flutter_inappwebview?.callHandler(
      'dmrCommand',
      event.deltaY > 0 ? 'next' : 'previous'
    );
  }, {passive:false});
  let touchX = 0, touchY = 0, touchInteractive = false;
  document.addEventListener('touchstart', (event) => {
    if (window.__dmrExternalInput) return;
    touchInteractive = isInteractiveTarget(event.target);
    if (touchInteractive) return;
    touchX = event.changedTouches[0].clientX; touchY = event.changedTouches[0].clientY;
  }, {passive:true});
  document.addEventListener('touchend', (event) => {
    if (window.__dmrExternalInput) return;
    const blocked = touchInteractive || isInteractiveTarget(event.target);
    touchInteractive = false;
    if (blocked) return;
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
