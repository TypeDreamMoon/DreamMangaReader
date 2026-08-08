import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models.dart';
import '../novel_document_sanitizer.dart';

enum NovelRenderBlockKind {
  paragraph,
  heading,
  quote,
  listItem,
  code,
  image,
  separator,
  spacer,
}

class NovelRenderInline {
  const NovelRenderInline({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.superscript = false,
    this.subscript = false,
    this.link,
    this.ruby,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final bool superscript;
  final bool subscript;
  final String? link;
  final String? ruby;

  NovelRenderInline copyWith({
    String? text,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikethrough,
    bool? superscript,
    bool? subscript,
    String? link,
    String? ruby,
  }) {
    return NovelRenderInline(
      text: text ?? this.text,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      strikethrough: strikethrough ?? this.strikethrough,
      superscript: superscript ?? this.superscript,
      subscript: subscript ?? this.subscript,
      link: link ?? this.link,
      ruby: ruby ?? this.ruby,
    );
  }
}

class NovelRenderBlock {
  NovelRenderBlock({
    required this.id,
    required this.kind,
    List<NovelRenderInline> inlines = const [],
    this.sourceId,
    this.headingLevel,
    this.marker,
    this.imageSource,
    this.imageAlt,
  }) : inlines = List.unmodifiable(inlines);

  final String id;
  final String? sourceId;
  final NovelRenderBlockKind kind;
  final List<NovelRenderInline> inlines;
  final int? headingLevel;
  final String? marker;
  final String? imageSource;
  final String? imageAlt;

  String get plainText => inlines.map((inline) => inline.text).join();
}

class NovelRenderDocument {
  NovelRenderDocument({required List<NovelRenderBlock> blocks})
      : blocks = List.unmodifiable(blocks);

  final List<NovelRenderBlock> blocks;

  String get plainText => blocks.map((block) => block.plainText).join('\n');
}

class NovelRenderDocumentParser {
  NovelRenderDocumentParser._();

  static NovelRenderDocument parse(NovelDocument document) {
    if (document.format == NovelDocumentFormat.text) {
      final lines = document.content.split(RegExp(r'\r\n?|\n'));
      return NovelRenderDocument(
        blocks: [
          for (var index = 0; index < lines.length; index++)
            NovelRenderBlock(
              id: 'dmr-$index',
              kind: lines[index].isEmpty
                  ? NovelRenderBlockKind.spacer
                  : NovelRenderBlockKind.paragraph,
              inlines: lines[index].isEmpty
                  ? const []
                  : [NovelRenderInline(text: lines[index])],
            ),
        ],
      );
    }

    final baseUrl =
        document.baseUrl == null ? null : Uri.tryParse(document.baseUrl!);
    final sanitized = NovelDocumentSanitizer.sanitize(
      document.content,
      baseUrl: baseUrl,
    );
    final fragment = html_parser.parseFragment(sanitized);
    return _HtmlRenderDocumentParser().parse(fragment);
  }
}

class _HtmlRenderDocumentParser {
  final List<NovelRenderBlock> _blocks = [];
  var _fallbackBlockId = 0;
  var _imageId = 0;

  NovelRenderDocument parse(dom.DocumentFragment fragment) {
    for (final node in fragment.nodes) {
      _visit(node);
    }
    return NovelRenderDocument(blocks: _blocks);
  }

  void _visit(dom.Node node) {
    if (node is! dom.Element) return;
    final name = node.localName ?? '';
    if (_textBlockNames.contains(name)) {
      _addTextBlock(node, name);
      return;
    }
    if (name == 'img') {
      _addImage(node);
      return;
    }
    if (name == 'hr') {
      _blocks.add(NovelRenderBlock(
        id: 'dmr-separator-${_fallbackBlockId++}',
        kind: NovelRenderBlockKind.separator,
      ));
      return;
    }
    for (final child in node.nodes) {
      _visit(child);
    }
  }

  void _addTextBlock(dom.Element element, String name) {
    final inlines = _inlineContent(element);
    if (inlines.isEmpty) return;
    final id =
        element.attributes['data-dmr-block'] ?? 'dmr-${_fallbackBlockId++}';
    final headingLevel =
        name.startsWith('h') ? int.tryParse(name.substring(1)) : null;
    _blocks.add(NovelRenderBlock(
      id: id,
      sourceId: element.id.isEmpty ? null : element.id,
      kind: _kindFor(name),
      headingLevel: headingLevel,
      marker: name == 'li' ? _listMarker(element) : null,
      inlines: inlines,
    ));
  }

  void _addImage(dom.Element element) {
    final source = element.attributes['src'];
    if (source == null || source.isEmpty) return;
    _blocks.add(NovelRenderBlock(
      id: 'dmr-image-${_imageId++}',
      kind: NovelRenderBlockKind.image,
      imageSource: source,
      imageAlt: element.attributes['alt'],
    ));
  }

  List<NovelRenderInline> _inlineContent(dom.Element element) {
    final result = <NovelRenderInline>[];
    void collect(dom.Node node, NovelRenderInline style) {
      if (node is dom.Text) {
        final text = element.localName == 'pre'
            ? node.data
            : node.data.replaceAll(RegExp(r'\s+'), ' ');
        if (text.isNotEmpty) result.add(style.copyWith(text: text));
        return;
      }
      if (node is! dom.Element) return;
      final name = node.localName;
      if (name == 'rt' || name == 'rp' || name == 'img') return;
      if (name == 'br') {
        result.add(style.copyWith(text: '\n'));
        return;
      }
      if (name == 'ruby') {
        final ruby = node.querySelector('rt')?.text.trim();
        final base = node.nodes
            .where((child) =>
                child is! dom.Element ||
                (child.localName != 'rt' && child.localName != 'rp'))
            .map((child) => child.text)
            .join()
            .trim();
        if (base.isNotEmpty) {
          result.add(style.copyWith(
            text: base,
            ruby: ruby == null || ruby.isEmpty ? null : ruby,
          ));
        }
        return;
      }
      final next = style.copyWith(
        bold: style.bold || name == 'b' || name == 'strong',
        italic: style.italic || name == 'i' || name == 'em',
        underline: style.underline || name == 'u',
        strikethrough: style.strikethrough || name == 's',
        superscript: style.superscript || name == 'sup',
        subscript: style.subscript || name == 'sub',
        link: name == 'a' ? node.attributes['href'] : style.link,
      );
      for (final child in node.nodes) {
        collect(child, next);
      }
    }

    const base = NovelRenderInline(text: '');
    for (final child in element.nodes) {
      collect(child, base);
    }
    if (result.isNotEmpty) {
      result[0] = result[0].copyWith(text: result[0].text.trimLeft());
      final last = result.length - 1;
      result[last] = result[last].copyWith(text: result[last].text.trimRight());
    }
    result.removeWhere((inline) => inline.text.isEmpty);
    return List.unmodifiable(result);
  }

  NovelRenderBlockKind _kindFor(String name) {
    if (name.startsWith('h')) return NovelRenderBlockKind.heading;
    return switch (name) {
      'blockquote' => NovelRenderBlockKind.quote,
      'li' || 'dd' || 'dt' || 'td' || 'th' => NovelRenderBlockKind.listItem,
      'pre' || 'code' => NovelRenderBlockKind.code,
      _ => NovelRenderBlockKind.paragraph,
    };
  }

  String? _listMarker(dom.Element element) {
    final parent = element.parent;
    if (parent == null) return null;
    final siblings = parent.children
        .where((child) => child.localName == 'li')
        .toList(growable: false);
    final index = siblings.indexOf(element);
    if (parent.localName != 'ol') return '•';
    final start = int.tryParse(parent.attributes['start'] ?? '') ?? 1;
    return '${start + (index < 0 ? 0 : index)}.';
  }
}

const _textBlockNames = {
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'p',
  'li',
  'blockquote',
  'pre',
  'figcaption',
  'dd',
  'dt',
  'td',
  'th',
};
