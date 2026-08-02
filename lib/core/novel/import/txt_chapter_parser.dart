import 'dart:convert';

class TxtNovelMetadata {
  const TxtNovelMetadata({this.title, this.author, this.preface = ''});

  final String? title;
  final String? author;
  final String preface;
}

class TxtParsedChapter {
  const TxtParsedChapter({
    required this.id,
    required this.title,
    required this.offset,
    required this.contentOffset,
    required this.endOffset,
    this.number,
    this.volumeId,
    this.volumeTitle,
  });

  final String id;
  final String title;
  final int offset;
  final int contentOffset;
  final int endOffset;
  final int? number;
  final String? volumeId;
  final String? volumeTitle;
}

class TxtParsedVolume {
  const TxtParsedVolume({
    required this.id,
    required this.title,
    required this.offset,
    required this.chapters,
  });

  final String id;
  final String title;
  final int offset;
  final List<TxtParsedChapter> chapters;
}

class TxtChapterParseResult {
  const TxtChapterParseResult({
    required this.normalizedText,
    required this.metadata,
    required this.chapters,
    required this.volumes,
  });

  final String normalizedText;
  final TxtNovelMetadata metadata;
  final List<TxtParsedChapter> chapters;
  final List<TxtParsedVolume> volumes;
}

class TxtChapterParser {
  static final RegExp _chapterPattern = RegExp(
    r'^\s*第([0-9０-９零〇一二两三四五六七八九十百千万]+)(章|回|节)(.*)$',
    unicode: true,
  );
  static final RegExp _volumePattern = RegExp(
    r'^\s*第?([0-9０-９零〇一二两三四五六七八九十百千万]+)(卷|部|篇|集|幕)(.*)$',
    unicode: true,
  );
  static final RegExp _sentencePunctuation = RegExp(r'[，,。！？!?；;：:…]');
  static final RegExp _authorPattern = RegExp(r'^\s*作\s*者\s*[:：]\s*(.+?)\s*$');
  static const Set<String> _specialHeadings = {
    '序章',
    '楔子',
    '引子',
    '前言',
    '番外',
    '后记',
    '尾声',
    '终章',
  };

  static TxtChapterParseResult parse(String source) {
    final normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = _buildLines(normalized);
    final candidates = _collectCandidates(lines);
    _applyContinuity(candidates);

    final accepted = candidates
        .where((candidate) => candidate.score >= candidate.threshold)
        .toList(growable: false);
    if (!accepted.any((candidate) => candidate.kind != _HeadingKind.volume)) {
      return _fallback(normalized);
    }

    final firstBoundary = accepted.first.line;
    final metadataText = normalized.substring(0, firstBoundary.codeUnitOffset);
    final metadata = _metadataFrom(metadataText);
    final totalBytes = utf8.encode(normalized).length;
    final chapters = <TxtParsedChapter>[];
    final volumeBuilders = <_VolumeBuilder>[];
    _VolumeBuilder? currentVolume;

    for (var index = 0; index < accepted.length; index++) {
      final candidate = accepted[index];
      if (candidate.kind == _HeadingKind.volume) {
        currentVolume = _VolumeBuilder(
          id: 'v${volumeBuilders.length + 1}',
          title: candidate.title,
          offset: candidate.line.byteOffset,
        );
        volumeBuilders.add(currentVolume);
        continue;
      }

      final nextOffset = index + 1 < accepted.length
          ? accepted[index + 1].line.byteOffset
          : totalBytes;
      final chapter = TxtParsedChapter(
        id: 'c${chapters.length + 1}',
        title: candidate.title,
        offset: candidate.line.byteOffset,
        contentOffset: candidate.line.contentByteOffset,
        endOffset: nextOffset,
        number: candidate.number,
        volumeId: currentVolume?.id,
        volumeTitle: currentVolume?.title,
      );
      chapters.add(chapter);
      currentVolume?.chapters.add(chapter);
    }

    return TxtChapterParseResult(
      normalizedText: normalized,
      metadata: TxtNovelMetadata(
        title: metadata.title,
        author: metadata.author,
        preface: metadataText.trim(),
      ),
      chapters: List.unmodifiable(chapters),
      volumes:
          List.unmodifiable(volumeBuilders.map((builder) => builder.build())),
    );
  }

  static List<_HeadingCandidate> _collectCandidates(List<_LineInfo> lines) {
    final candidates = <_HeadingCandidate>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final trimmed = line.text.trim();
      if (trimmed.isEmpty) continue;

      _HeadingCandidate? candidate;
      final chapterMatch = _chapterPattern.firstMatch(trimmed);
      if (chapterMatch != null) {
        candidate = _HeadingCandidate(
          line: line,
          title: trimmed,
          kind: _HeadingKind.chapter,
          number: _parseNumber(chapterMatch.group(1)!),
          score: 4,
        );
      } else if (_specialHeadings.contains(trimmed)) {
        candidate = _HeadingCandidate(
          line: line,
          title: trimmed,
          kind: _HeadingKind.special,
          score: 3,
        );
      } else {
        final volumeMatch = _volumePattern.firstMatch(trimmed);
        if (volumeMatch != null && _validVolumeTail(volumeMatch.group(3)!)) {
          candidate = _HeadingCandidate(
            line: line,
            title: trimmed,
            kind: _HeadingKind.volume,
            number: _parseNumber(volumeMatch.group(1)!),
            score: 3,
          );
        }
      }
      if (candidate == null) continue;

      final blankBefore = index == 0 || lines[index - 1].text.trim().isEmpty;
      final blankAfter =
          index == lines.length - 1 || lines[index + 1].text.trim().isEmpty;
      if (blankBefore) candidate.score += 2;
      if (blankAfter) candidate.score += 1;
      if (!blankBefore &&
          candidate.kind == _HeadingKind.volume &&
          _isMetadataPrefix(lines.take(index))) {
        candidate.score += 2;
      }
      if (_sentencePunctuation.hasMatch(trimmed)) candidate.score -= 4;
      if (trimmed.runes.length > 80) candidate.score -= 4;
      candidates.add(candidate);
    }
    return candidates;
  }

  static void _applyContinuity(List<_HeadingCandidate> candidates) {
    final numbered = candidates
        .where((candidate) =>
            candidate.kind == _HeadingKind.chapter && candidate.number != null)
        .toList(growable: false);
    for (var index = 0; index < numbered.length; index++) {
      final number = numbered[index].number!;
      final followsPrevious =
          index > 0 && number == numbered[index - 1].number! + 1;
      final precedesNext = index + 1 < numbered.length &&
          numbered[index + 1].number == number + 1;
      if (followsPrevious || precedesNext) numbered[index].score += 2;
    }
  }

  static bool _validVolumeTail(String tail) {
    if (tail.isEmpty) return true;
    final first = tail.runes.first;
    return first == 0x20 ||
        first == 0x3000 ||
        '，,。！？!?；;：:、.-—…'.runes.contains(first);
  }

  static bool _isMetadataPrefix(Iterable<_LineInfo> lines) {
    final values = lines
        .map((line) => line.text.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return values.length <= 4 && values.any(_authorPattern.hasMatch);
  }

  static TxtNovelMetadata _metadataFrom(String text) {
    final lines = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    String? author;
    for (final line in lines) {
      final match = _authorPattern.firstMatch(line);
      if (match != null) {
        author = match.group(1)!.trim();
        break;
      }
    }
    String? title;
    for (final line in lines) {
      if (_authorPattern.hasMatch(line) || line.startsWith('内容简介')) continue;
      if (line.runes.length <= 80) {
        title = line;
        break;
      }
    }
    return TxtNovelMetadata(title: title, author: author, preface: text.trim());
  }

  static TxtChapterParseResult _fallback(String normalized) {
    final totalBytes = utf8.encode(normalized).length;
    return TxtChapterParseResult(
      normalizedText: normalized,
      metadata: const TxtNovelMetadata(),
      chapters: [
        TxtParsedChapter(
          id: 'c1',
          title: '正文',
          offset: 0,
          contentOffset: 0,
          endOffset: totalBytes,
        ),
      ],
      volumes: const [],
    );
  }

  static List<_LineInfo> _buildLines(String text) {
    final values = text.split('\n');
    final lines = <_LineInfo>[];
    var byteOffset = 0;
    var codeUnitOffset = 0;
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      final hasNewline = index < values.length - 1;
      final byteLength = utf8.encode(value).length;
      lines.add(_LineInfo(
        text: value,
        byteOffset: byteOffset,
        contentByteOffset: byteOffset + byteLength + (hasNewline ? 1 : 0),
        codeUnitOffset: codeUnitOffset,
      ));
      byteOffset += byteLength + (hasNewline ? 1 : 0);
      codeUnitOffset += value.length + (hasNewline ? 1 : 0);
    }
    return lines;
  }
}

enum _HeadingKind { chapter, special, volume }

class _LineInfo {
  const _LineInfo({
    required this.text,
    required this.byteOffset,
    required this.contentByteOffset,
    required this.codeUnitOffset,
  });

  final String text;
  final int byteOffset;
  final int contentByteOffset;
  final int codeUnitOffset;
}

class _HeadingCandidate {
  _HeadingCandidate({
    required this.line,
    required this.title,
    required this.kind,
    required this.score,
    this.number,
  });

  final _LineInfo line;
  final String title;
  final _HeadingKind kind;
  final int? number;
  int score;

  int get threshold => kind == _HeadingKind.volume ? 5 : 4;
}

class _VolumeBuilder {
  _VolumeBuilder({
    required this.id,
    required this.title,
    required this.offset,
  });

  final String id;
  final String title;
  final int offset;
  final List<TxtParsedChapter> chapters = [];

  TxtParsedVolume build() => TxtParsedVolume(
        id: id,
        title: title,
        offset: offset,
        chapters: List.unmodifiable(chapters),
      );
}

int? _parseNumber(String source) {
  final normalized = source.replaceAllMapped(
    RegExp(r'[０-９]'),
    (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xfee0),
  );
  final arabic = int.tryParse(normalized);
  if (arabic != null) return arabic;

  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (!normalized.contains(RegExp(r'[十百千万]'))) {
    var value = 0;
    for (final rune in normalized.runes) {
      final digit = digits[String.fromCharCode(rune)];
      if (digit == null) return null;
      value = value * 10 + digit;
    }
    return value;
  }

  const units = {'十': 10, '百': 100, '千': 1000};
  var total = 0;
  var section = 0;
  var number = 0;
  for (final rune in normalized.runes) {
    final character = String.fromCharCode(rune);
    final digit = digits[character];
    if (digit != null) {
      number = digit;
      continue;
    }
    if (character == '万') {
      section += number;
      total += (section == 0 ? 1 : section) * 10000;
      section = 0;
      number = 0;
      continue;
    }
    final unit = units[character];
    if (unit == null) return null;
    section += (number == 0 ? 1 : number) * unit;
    number = 0;
  }
  return total + section + number;
}
