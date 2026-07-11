import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/theme/app_colors.dart';

/// 轻量 **Markdown** 渲染(自包含,不引第三方包;完全跟随 [AppPalette] 配色)。
///
/// 覆盖 GitHub Release Note 常用子集:`#`~`###` 标题、`**粗**`/`*斜*`、
/// `` `行内代码` ``、``` ``` 代码块、`-`/`*`/`1.` 列表(含缩进)、`|表格|`、
/// `>` 引用、`---` 分隔线、`[文字](链接)`。不识别的记号原样退化为文本
/// (输入是我们自己写的 Release Note,不追求完整 CommonMark)。
///
/// 目前用于「发现新版本」更新弹窗;其它需要展示 Markdown 的地方(关于页等)可复用。
class MarkdownView extends StatefulWidget {
  const MarkdownView(this.data, {super.key, this.baseStyle});

  final String data;

  /// 正文基准样式(颜色/字号/行高);标题、引用等在此基础上再调整。
  final TextStyle? baseStyle;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  // 链接点击识别器:随 build 重建,dispose 时统一释放,避免泄漏。
  final List<TapGestureRecognizer> _recognizers = [];

  static const _mono = 'monospace';
  static const _monoFallback = ['Consolas', 'Courier New', 'monospace'];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers(); // 上一帧的识别器已随旧 span 弃用,重建前先清掉
    final p = context.palette;
    final base = (widget.baseStyle ??
            TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.5))
        .copyWith(color: widget.baseStyle?.color ?? p.textMuted);
    final blocks = _parse(widget.data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : _gapBefore(blocks[i])),
            child: _renderBlock(blocks[i], base, p),
          ),
      ],
    );
  }

  double _gapBefore(_Block b) => switch (b) {
        _Heading() => 12,
        _Rule() => 10,
        _ => 6,
      };

  // ---- 渲染 ----

  Widget _renderBlock(_Block b, TextStyle base, AppPalette p) {
    switch (b) {
      case _Heading(:final level, :final text):
        final size = switch (level) { 1 => 16.0, 2 => 14.5, _ => 13.0 };
        return _richLine(
            text,
            base.copyWith(
                color: p.textPrimary,
                fontSize: size,
                height: 1.3,
                fontWeight: FontWeight.w800),
            p);
      case _Para(:final text):
        return _richLine(text, base, p);
      case _Rule():
        return Divider(height: 1, thickness: 1, color: p.line);
      case _Code(:final text):
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: p.elevated,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.line),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(text,
                style: base.copyWith(
                    fontFamily: _mono,
                    fontFamilyFallback: _monoFallback,
                    color: p.textPrimary,
                    height: 1.4)),
          ),
        );
      case _Quote(:final text):
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: 0.08),
            border: Border(left: BorderSide(color: p.accent, width: 3)),
            borderRadius: const BorderRadius.only(
                topRight: Radius.circular(6), bottomRight: Radius.circular(6)),
          ),
          child: _richLine(text, base, p),
        );
      case _ListBlock(:final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final li in items)
              Padding(
                padding: EdgeInsets.only(left: 2 + li.indent * 14.0, bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 0.5, right: 6),
                      child: Text(li.ordered ? '${li.number}.' : '•',
                          style: base.copyWith(color: p.accent)),
                    ),
                    Expanded(child: _richLine(li.text, base, p)),
                  ],
                ),
              ),
          ],
        );
      case _Table(:final rows, :final align):
        return _renderTable(rows, align, base, p);
    }
  }

  Widget _renderTable(
      List<List<String>> rows, List<int> align, TextStyle base, AppPalette p) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows.map((r) => r.length).fold(0, (a, b) => a > b ? a : b);
    TextAlign alignOf(int c) => switch (c < align.length ? align[c] : 0) {
          1 => TextAlign.center,
          2 => TextAlign.right,
          _ => TextAlign.left,
        };
    Widget cell(String text, int c, bool header) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: _richLine(
                text,
                header
                    ? base.copyWith(
                        color: p.textPrimary, fontWeight: FontWeight.w700)
                    : base,
                p,
                align: alignOf(c)),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rows.length; i++)
            Container(
              decoration: BoxDecoration(
                color: i == 0 ? p.elevated : null,
                border: i == rows.length - 1
                    ? null
                    : Border(bottom: BorderSide(color: p.line)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var c = 0; c < cols; c++)
                    cell(c < rows[i].length ? rows[i][c] : '', c, i == 0),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _richLine(String text, TextStyle style, AppPalette p,
          {TextAlign align = TextAlign.left}) =>
      Text.rich(TextSpan(children: _inlineSpans(text, style, p)),
          textAlign: align);

  // ---- 行内解析:`code` / [text](url) / **bold** / *italic* ----

  List<InlineSpan> _inlineSpans(String s, TextStyle base, AppPalette p) {
    final spans = <InlineSpan>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        spans.add(TextSpan(text: buf.toString(), style: base));
        buf.clear();
      }
    }

    var i = 0;
    while (i < s.length) {
      final c = s[i];
      // 行内代码 `code`
      if (c == '`') {
        final end = s.indexOf('`', i + 1);
        if (end > i) {
          flush();
          spans.add(TextSpan(
            text: s.substring(i + 1, end),
            style: base.copyWith(
              fontFamily: _mono,
              fontFamilyFallback: _monoFallback,
              color: p.accentSoft,
              backgroundColor: p.elevated,
            ),
          ));
          i = end + 1;
          continue;
        }
      }
      // 链接 [text](url)
      if (c == '[') {
        final m =
            RegExp(r'^\[([^\]]+)\]\(([^)\s]+)\)').firstMatch(s.substring(i));
        if (m != null) {
          flush();
          final url = m.group(2)!;
          final rec = TapGestureRecognizer()
            ..onTap = () => launchUrl(Uri.parse(url),
                mode: LaunchMode.externalApplication);
          _recognizers.add(rec);
          spans.add(TextSpan(
            text: m.group(1),
            style: base.copyWith(
                color: p.accent, decoration: TextDecoration.underline),
            recognizer: rec,
          ));
          i += m.end;
          continue;
        }
      }
      // 粗体 **bold**
      if (c == '*' && i + 1 < s.length && s[i + 1] == '*') {
        final end = s.indexOf('**', i + 2);
        if (end > i + 1) {
          flush();
          spans.addAll(_inlineSpans(s.substring(i + 2, end),
              base.copyWith(fontWeight: FontWeight.w800), p));
          i = end + 2;
          continue;
        }
      }
      // 斜体 *italic*(不支持 `_`,避免误伤 snake_case / 文件名)。
      // 要求 `*` 紧跟非空格非 `*`、且闭合 `*` 左侧非空格——否则「see ** here」「2 * 3」
      // 里的裸星号会被吞成空斜体、丢字符,退化为字面量才对。
      if (c == '*' && i + 1 < s.length && s[i + 1] != ' ' && s[i + 1] != '*') {
        final end = s.indexOf('*', i + 1);
        if (end > i + 1 && s[end - 1] != ' ') {
          flush();
          spans.addAll(_inlineSpans(s.substring(i + 1, end),
              base.copyWith(fontStyle: FontStyle.italic), p));
          i = end + 1;
          continue;
        }
      }
      buf.write(c);
      i++;
    }
    flush();
    return spans;
  }

  // ---- 块解析 ----

  List<_Block> _parse(String src) {
    final lines = src.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final out = <_Block>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final t = line.trim();
      if (t.isEmpty) {
        i++;
        continue;
      }
      // 代码块 ```
      if (t.startsWith('```')) {
        final body = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          body.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // 吃掉结尾 ```
        out.add(_Code(body.join('\n')));
        continue;
      }
      // 表格:本行含 | 且下一行是分隔行
      if (line.contains('|') &&
          i + 1 < lines.length &&
          _isTableSep(lines[i + 1])) {
        final rows = <List<String>>[_tableCells(line)];
        final align = _tableAlign(lines[i + 1]);
        i += 2;
        while (i < lines.length &&
            lines[i].contains('|') &&
            lines[i].trim().isNotEmpty) {
          rows.add(_tableCells(lines[i]));
          i++;
        }
        out.add(_Table(rows, align));
        continue;
      }
      // 标题 #..######
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(t);
      if (h != null) {
        out.add(_Heading(h.group(1)!.length, h.group(2)!.trim()));
        i++;
        continue;
      }
      // 分隔线
      if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(t)) {
        out.add(_Rule());
        i++;
        continue;
      }
      // 引用块 >(连续)
      if (t.startsWith('>')) {
        final quote = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          quote.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
          i++;
        }
        out.add(_Quote(quote.join(' ').trim()));
        continue;
      }
      // 列表(连续)
      if (_listItem(line) != null) {
        final items = <_Li>[];
        while (i < lines.length && _listItem(lines[i]) != null) {
          items.add(_listItem(lines[i])!);
          i++;
        }
        out.add(_ListBlock(items));
        continue;
      }
      // 段落:先**无条件吃掉当前行**(它已落到段落分支 = 不是任何块类型),
      // 保证 i 至少前进一格(不会死循环);再合并后续普通行到下一个块起点为止。
      final para = <String>[t];
      i++;
      while (i < lines.length && !_startsBlock(lines, i)) {
        para.add(lines[i].trim());
        i++;
      }
      out.add(_Para(para.join(' ')));
    }
    return out;
  }

  /// 行 [i] 是否为一个「非段落块」的起点——段落合并的终止判据,**必须与 [_parse]
  /// 里各分发器一字不差**(否则会误合并,或第一行就 break 导致死循环)。
  bool _startsBlock(List<String> lines, int i) {
    final l = lines[i];
    final t = l.trim();
    if (t.isEmpty) return true; // 空行结束段落
    if (t.startsWith('```')) return true;
    if (RegExp(r'^#{1,6}\s+').hasMatch(t)) return true;
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(t)) return true;
    if (t.startsWith('>')) return true;
    if (_listItem(l) != null) return true;
    if (l.contains('|') &&
        i + 1 < lines.length &&
        _isTableSep(lines[i + 1])) {
      return true;
    }
    return false;
  }

  _Li? _listItem(String line) {
    final m = RegExp(r'^(\s*)([-*+]|\d+\.)\s+(.*)$').firstMatch(line);
    if (m == null) return null;
    final indent = (m.group(1)!.length ~/ 2).clamp(0, 4);
    final marker = m.group(2)!;
    final ordered = marker.endsWith('.');
    return _Li(
      indent: indent,
      ordered: ordered,
      number: ordered ? (int.tryParse(marker.replaceAll('.', '')) ?? 1) : 0,
      text: m.group(3)!.trim(),
    );
  }

  bool _isTableSep(String line) {
    final t = line.trim();
    // 必须含 `|`:否则裸 `---` 会被当成表格分隔行,把它前面带 `|` 的普通行
    // 吞成幽灵单行表、还吃掉本该是分隔线的 `---`(应落到 _Rule)。
    if (!t.contains('-') || !t.contains('|')) return false;
    return RegExp(r'^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$').hasMatch(t);
  }

  /// 表格分隔行 → 各列对齐(0=左 1=中 2=右)。
  List<int> _tableAlign(String line) => [
        for (final c in _rawCells(line))
          () {
            final s = c.trim();
            final l = s.startsWith(':');
            final r = s.endsWith(':');
            return l && r ? 1 : (r ? 2 : 0);
          }()
      ];

  List<String> _tableCells(String line) =>
      _rawCells(line).map((c) => c.trim()).toList();

  /// 按 `|` 切分,去掉首尾外框管道产生的空单元。
  List<String> _rawCells(String line) {
    var t = line.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|')) t = t.substring(0, t.length - 1);
    return t.split('|');
  }
}

// ---- 块模型 ----

sealed class _Block {}

class _Heading extends _Block {
  _Heading(this.level, this.text);
  final int level;
  final String text;
}

class _Para extends _Block {
  _Para(this.text);
  final String text;
}

class _Rule extends _Block {}

class _Code extends _Block {
  _Code(this.text);
  final String text;
}

class _Quote extends _Block {
  _Quote(this.text);
  final String text;
}

class _ListBlock extends _Block {
  _ListBlock(this.items);
  final List<_Li> items;
}

class _Li {
  _Li(
      {required this.indent,
      required this.ordered,
      required this.number,
      required this.text});
  final int indent;
  final bool ordered;
  final int number;
  final String text;
}

class _Table extends _Block {
  _Table(this.rows, this.align);
  final List<List<String>> rows;
  final List<int> align;
}
