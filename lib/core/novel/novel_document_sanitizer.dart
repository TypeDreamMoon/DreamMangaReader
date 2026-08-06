import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

class NovelDocumentSanitizer {
  const NovelDocumentSanitizer._();

  static const _allowedElements = {
    'a',
    'article',
    'b',
    'blockquote',
    'br',
    'caption',
    'code',
    'dd',
    'div',
    'dl',
    'dt',
    'em',
    'figcaption',
    'figure',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'hr',
    'i',
    'img',
    'li',
    'ol',
    'p',
    'pre',
    'rp',
    'rt',
    'ruby',
    's',
    'section',
    'small',
    'span',
    'strong',
    'sub',
    'sup',
    'table',
    'tbody',
    'td',
    'tfoot',
    'th',
    'thead',
    'tr',
    'u',
    'ul',
  };

  static const _dropWithContents = {
    'audio',
    'button',
    'canvas',
    'embed',
    'form',
    'iframe',
    'input',
    'link',
    'meta',
    'noscript',
    'object',
    'script',
    'select',
    'style',
    'svg',
    'template',
    'textarea',
    'video',
  };

  static const _globalAttributes = {'dir', 'id', 'lang', 'title'};

  static String sanitize(String source, {Uri? baseUrl}) {
    final fragment = html_parser.parseFragment(source);
    for (final element in fragment.querySelectorAll('*').toList().reversed) {
      final name = element.localName;
      if (_dropWithContents.contains(name)) {
        element.remove();
        continue;
      }
      if (!_allowedElements.contains(name)) {
        _unwrap(element);
        continue;
      }
      _sanitizeAttributes(element, baseUrl);
    }

    var block = 0;
    for (final element in fragment.querySelectorAll(
      'h1, h2, h3, h4, h5, h6, p',
    )) {
      element.attributes['data-dmr-block'] = 'dmr-${block++}';
    }
    return fragment.outerHtml;
  }

  static void _sanitizeAttributes(dom.Element element, Uri? baseUrl) {
    final retained = <String, String>{};
    for (final entry in element.attributes.entries) {
      final name = entry.key.toString().toLowerCase();
      final value = entry.value;
      if (_globalAttributes.contains(name)) {
        retained[name] = value;
      }
    }

    if (element.localName == 'a') {
      final href = _safeUrl(element.attributes['href'], baseUrl);
      if (href != null) retained['href'] = href;
    } else if (element.localName == 'img') {
      final src = _safeUrl(
        element.attributes['src'],
        baseUrl,
        allowDataImage: true,
      );
      if (src != null) retained['src'] = src;
      final alt = element.attributes['alt'];
      if (alt != null) retained['alt'] = alt;
      final width = _safeDimension(element.attributes['width']);
      final height = _safeDimension(element.attributes['height']);
      if (width != null) retained['width'] = width;
      if (height != null) retained['height'] = height;
    } else if (element.localName == 'td' || element.localName == 'th') {
      final colspan = _safeDimension(element.attributes['colspan']);
      final rowspan = _safeDimension(element.attributes['rowspan']);
      if (colspan != null) retained['colspan'] = colspan;
      if (rowspan != null) retained['rowspan'] = rowspan;
    } else if (element.localName == 'ol') {
      final start = int.tryParse(element.attributes['start'] ?? '');
      if (start != null) retained['start'] = '$start';
    }

    element.attributes
      ..clear()
      ..addAll(retained);
  }

  static String? _safeUrl(
    String? value,
    Uri? baseUrl, {
    bool allowDataImage = false,
  }) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.startsWith('#')) return trimmed;
    if (allowDataImage &&
        RegExp(
          r'^data:image/(?:png|jpeg|gif|webp);base64,[A-Za-z0-9+/]+={0,2}$',
          caseSensitive: false,
        ).hasMatch(trimmed)) {
      return trimmed;
    }
    try {
      final parsed = Uri.parse(trimmed);
      final resolved = baseUrl?.resolveUri(parsed) ?? parsed;
      if (!resolved.hasScheme) return resolved.toString();
      if (resolved.scheme == 'http' || resolved.scheme == 'https') {
        return resolved.toString();
      }
      if (resolved.scheme == 'file' && baseUrl?.scheme == 'file') {
        return resolved.toString();
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static String? _safeDimension(String? value) {
    final number = int.tryParse(value ?? '');
    return number != null && number > 0 && number <= 100000 ? '$number' : null;
  }

  static void _unwrap(dom.Element element) {
    final parent = element.parentNode;
    if (parent == null) return;
    for (final child in element.nodes.toList()) {
      parent.insertBefore(child, element);
    }
    element.remove();
  }
}
