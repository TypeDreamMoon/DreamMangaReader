/// 本地剧集文件名解析：从文件名里提取标题与季/集号，并提供自然排序、字幕配对。
///
/// 对应设计文档 docs/superpowers/specs/2026-09-30-local-playback-design.md §5.3。
/// 全是纯字符串运算：不依赖 dart:io、也不依赖 Flutter —— 「Windows 目录扫描」
/// 和「Android SAF 查询」拿到的文件名都能直接喂进来，因此可以直接单测。
///
/// 输入约定：传**文件名**（最后一段），不是完整路径。
library;

/// 解析出的媒体名：清理后的标题 + 可选的季/集号。
class ParsedMediaName {
  const ParsedMediaName({required this.title, this.season, this.episode});

  /// 清理后的标题：去扩展名，去分辨率/编码/字幕组等噪声，分隔符归一为单空格。
  final String title;

  /// 季号；解析不到为 null。**不默认成 1** —— 「没写季号」和「第一季」是两回事，
  /// 猜错了会把剧场版塞进第一季的集数序列里。
  final int? season;

  /// 集号；解析不到为 null（剧场版、特典、整季合辑都走这条路）。
  final int? episode;

  @override
  String toString() =>
      'ParsedMediaName(title: "$title", season: $season, episode: $episode)';
}

/// 一条季集规则的一次命中：字符区间 [start, end) 与解析出的季/集号。
///
/// 记区间是为了能把命中的那一段从标题里抠掉 —— 标题里不该留着 "S01E02"。
class _EpisodeMatch {
  const _EpisodeMatch(this.start, this.end, {this.season, this.episode});

  final int start;
  final int end;
  final int? season;
  final int? episode;
}

/// 季集规则 = 一个正则 + 把首个匹配翻译成 [_EpisodeMatch]。
/// 翻译函数返回 null 表示「看着像但其实是别的东西」（例如尾部年份），该规则作废。
typedef _EpisodeResolver = _EpisodeMatch? Function(RegExpMatch match);

class _EpisodeRule {
  const _EpisodeRule(this.pattern, this.resolve);

  final RegExp pattern;
  final _EpisodeResolver resolve;

  _EpisodeMatch? firstMatch(String text) {
    final match = pattern.firstMatch(text);
    return match == null ? null : resolve(match);
  }
}

// ——————————————————————— 季集识别的正则（按优先级排列）———————————————————————

/// 强特征：`S01E02`、`s1e2`、`S01.E02`、`S01_EP2`、`S01 E02`。
///
/// 故意不加 `\b` 之类的左边界：`[Group]S01E02` 这种没有分隔符的写法也该认出来，
/// 而 `[Ss]\d+[Ee]\d+` 的形状在普通单词里几乎不可能出现，误报风险很低。
final RegExp _seasonEpisodePattern = RegExp(
  r'[Ss](\d{1,3})[\s._-]*[Ee][Pp]?\s*[._-]?\s*(\d{1,4})(?!\d)',
);

/// `1x02`（季 x 集）。前后都排除数字，否则 `1920x1080` 会被读成 S920E1080。
final RegExp _crossPattern = RegExp(
  r'(?<!\d)(\d{1,2})\s*[xX]\s*(\d{1,4})(?!\d)',
);

/// `第12话/話/集/期/部`。番剧语境里「期」「部」就是集的意思（第3期 = 第三期）。
final RegExp _chineseEpisodePattern = RegExp(r'第\s*(\d{1,4})\s*[话話集期部]');

/// `EP12` / `E12` / `E.12` / `E - 12`。
///
/// 左边要求不是字母数字，右边最多两个分隔符：这样 `Episode` 这种单词天然匹配不上
/// （E 后面跟的是 `pisode` 而不是数字），`3e12` 这种也算不出来。
final RegExp _episodePrefixPattern = RegExp(
  r'(?<![A-Za-z0-9])[Ee][Pp]?[._\-\s]{0,2}(\d{1,4})(?!\d)',
);

/// 方括号里只有数字：`[12]`。限制 1~3 位，免得 `[2020]` 这种年份被当成集号。
final RegExp _bracketEpisodePattern = RegExp(r'[\[\({【]\s*(\d{1,3})\s*[\]\)}】]');

/// 尾部集号：`Show - 12`、`Show 12`、纯数字文件名 `12`。
///
/// 允许数字后面再跟一串噪声方括号 —— `Show - 12 [1080p][x264]` 是极常见的命名，
/// 只认「数字结尾」会漏掉一大半。
final RegExp _trailingEpisodePattern = RegExp(
  r'(?:^|[\s\-_.–—])(\d{1,4})(?:\s*[\[\({【][^\]\)}】]{0,24}[\]\)}】])*\s*$',
);

/// `第2季`。
final RegExp _chineseSeasonPattern = RegExp(r'第\s*(\d{1,3})\s*季');

/// `Season 2` / `Season.2`。
final RegExp _seasonWordPattern = RegExp(
  r'[Ss]eason[\s._-]{0,2}(\d{1,3})(?!\d)',
);

/// 裸的 `S02`（`Show.S02.1080p`）。
///
/// 右边界必须是「非单词字符或结尾」，否则 `S1mpsons` 会被读成第一季。
final RegExp _bareSeasonPattern = RegExp(
  r'(?<![A-Za-z0-9])[Ss](\d{1,3})(?![\w])',
);

/// 尾部 4 位数落在这个区间就当年份（`Dune.2021` 不是第 2021 集）。
const int _minYear = 1900;
const int _maxYear = 2099;

/// 集号规则：命中即停，所以顺序 = 优先级。
final List<_EpisodeRule> _seasonEpisodeRules = <_EpisodeRule>[
  _EpisodeRule(
    _seasonEpisodePattern,
    (match) => _EpisodeMatch(
      match.start,
      match.end,
      season: int.parse(match[1]!),
      episode: int.parse(match[2]!),
    ),
  ),
  _EpisodeRule(
    _crossPattern,
    (match) => _EpisodeMatch(
      match.start,
      match.end,
      season: int.parse(match[1]!),
      episode: int.parse(match[2]!),
    ),
  ),
  _EpisodeRule(
    _chineseEpisodePattern,
    (match) => _EpisodeMatch(
      match.start,
      match.end,
      episode: int.parse(match[1]!),
    ),
  ),
  _EpisodeRule(
    _episodePrefixPattern,
    (match) => _EpisodeMatch(
      match.start,
      match.end,
      episode: int.parse(match[1]!),
    ),
  ),
  _EpisodeRule(
    _bracketEpisodePattern,
    (match) => _EpisodeMatch(
      match.start,
      match.end,
      episode: int.parse(match[1]!),
    ),
  ),
  _EpisodeRule(_trailingEpisodePattern, _resolveTrailingEpisode),
];

/// 只有季号时（`Show S02`、`Show 第2季`）的兜底规则。
final List<_EpisodeRule> _seasonOnlyRules = <_EpisodeRule>[
  _EpisodeRule(
    _chineseSeasonPattern,
    (match) => _EpisodeMatch(
      match.start,
      match.end,
      season: int.parse(match[1]!),
    ),
  ),
  _EpisodeRule(
    _seasonWordPattern,
    (match) => _EpisodeMatch(
      match.start,
      match.end,
      season: int.parse(match[1]!),
    ),
  ),
  _EpisodeRule(
    _bareSeasonPattern,
    (match) => _EpisodeMatch(
      match.start,
      match.end,
      season: int.parse(match[1]!),
    ),
  ),
];

_EpisodeMatch? _resolveTrailingEpisode(RegExpMatch match) {
  final value = int.parse(match[1]!);
  // 前面还有标题 + 4 位数落在年份区间 → 那是影片年份，不是集号。
  // 文件名本身就是数字（"2020.mkv"）时不套这条：那种情况它只能是集号。
  if (match.start > 0 && value >= _minYear && value <= _maxYear) return null;
  return _EpisodeMatch(match.start, match.end, episode: value);
}

// ——————————————————————————————— 噪声清理 ———————————————————————————————

/// 分辨率/编码/来源/音轨/位深。前后都要求不是字母数字，避免切坏正常单词
/// （`bd` 这种短词排在 `bdrip` 后面，靠交替顺序保证先吃长的）。
final RegExp _noiseTokenPattern = RegExp(
  r'(?<![A-Za-z0-9])(?:'
  r'2160p|1440p|1080p|720p|576p|480p|360p|4k|8k|'
  r'x265|x264|h\.?265|h\.?264|hevc|avc|av1|vp9|xvid|divx|hi10p|10bit|8bit|'
  r'web[-_.]?dl|web[-_.]?rip|blu[-_.]?ray|bdrip|brrip|remux|bd|hdtv|dvdrip|hdrip|uhd|'
  r'aac|eac3|ac3|dts[-_.]?hd|dts|truehd|flac|v2'
  r')(?![A-Za-z0-9])',
  caseSensitive: false,
);

/// `1920x1080` 这种「宽x高」。集号识别里已经挡过一次，这里再从标题里清掉。
final RegExp _resolutionPattern = RegExp(r'(?<!\d)\d{3,4}\s*[xX]\s*\d{3,4}(?!\d)');

/// 中文标签：出现在标题里纯属附注，不是作品名的一部分。
final RegExp _noiseTagPattern = RegExp(
  r'简繁|简体|繁体|简中|繁中|中字|双语|内嵌|外挂|无修|合集|全集',
);

/// 方括号块：`[字幕组]`、`(1080p)`、`{x265}`、`[ABCD1234]`、`【测试】`。
/// 只吃一层：`[A][B]` 会匹配成两块。
final RegExp _bracketBlockPattern = RegExp(
  r'[\[\({【]\s*([^\[\](){}【】]*?)\s*[\]\)}】]',
);

/// 方括号里的内容出现这些词，基本可以断定是字幕组/标签而不是作品名。
final RegExp _bracketTagPattern = RegExp(
  r'字幕|压制|发布|发佈|制作|翻译|简繁|简体|繁体|简中|繁中|中字|双语|内嵌|外挂|合集|全集|无修|raws?',
  caseSensitive: false,
);

/// CRC32：`[ABCD1234]`。
final RegExp _crcPattern = RegExp(r'^[0-9A-Fa-f]{8}$');

/// 括号里只包一个年份：`Movie (2019)`。
final RegExp _bracketYearPattern = RegExp(r'^(?:19|20)\d{2}$');

/// 空括号（噪声清完剩下的壳）。
final RegExp _emptyBracketPattern = RegExp(r'[\[\({【]\s*[\]\)}】]');

/// 开头的方括号块没有空格且不长 → 按粉丝压制约定是字幕组名（`[FLsnow]`、
/// `[Lilith-Raws]`），直接删；带空格的（`[Movie Title]`）留着，那多半是标题。
const int _maxLeadingGroupLength = 24;

/// 分隔符：下划线、点、连字符、破折号、间隔号、空白，一律归一成单空格。
final RegExp _separatorPattern = RegExp(r'[\s_\-–—.·]+');

/// 全角字符：数字/字母/括号/空格。日文命名里 `第０１話`、`Ｓ０１Ｅ０２` 都真实存在。
final RegExp _fullWidthPattern = RegExp(
  r'[\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A\uFF08\uFF09\uFF3B\uFF3D\uFF5B\uFF5D\u3010\u3011\u3000]',
);

const Map<int, String> _fullWidthReplacements = <int, String>{
  0xFF08: '(',
  0xFF09: ')',
  0xFF3B: '[',
  0xFF3D: ']',
  0xFF5B: '{',
  0xFF5D: '}',
  0x3010: '[',
  0x3011: ']',
};

/// 取扩展名用的正则：只看最后一段，且必须以字母开头（`mkv`、`m2ts`、`ass`）。
/// 这样 `Naruto.12` 里的 `.12` 不会被当成扩展名吃掉，尾部集号还能救回来。
final RegExp _extensionPattern = RegExp(r'\.[A-Za-z][A-Za-z0-9]{0,5}$');

// ——————————————————————————————— 公开 API ———————————————————————————————

/// 从「文件名」（不是完整路径）解析标题与季集号。
ParsedMediaName parseMediaFileName(String fileName) {
  final normalized = _toHalfWidth(fileName.trim());
  final base = _stripExtension(normalized);
  if (base.isEmpty) return const ParsedMediaName(title: '');

  final spans = <_EpisodeMatch>[];
  int? season;
  int? episode;

  for (final rule in _seasonEpisodeRules) {
    final match = rule.firstMatch(base);
    if (match == null) continue;
    spans.add(match);
    season = match.season;
    episode = match.episode;
    break;
  }

  // 只有季号的命名（`Show S02`、`Show 第2季`）：等集号规则全落空再找一次，
  // 免得把 `Show S02E05` 的季号重复匹配第二遍。
  if (season == null) {
    for (final rule in _seasonOnlyRules) {
      final match = rule.firstMatch(base);
      if (match == null) continue;
      spans.add(match);
      season = match.season;
      break;
    }
  }

  return ParsedMediaName(
    title: _finalizeTitle(withoutEpisode: _removeSpans(base, spans), base: base),
    season: season,
    episode: episode,
  );
}

/// 自然排序：数字段按数值比（`10` 在 `9` 之后），其余按大小写不敏感字典序。
///
/// 只有大小写不同的两个串返回 0（本函数就是大小写不敏感的）。要稳定的全序请用
/// [compareEpisodes]，它在最后补了一次原始文件名的比较。
int compareNatural(String a, String b) {
  final left = a.toLowerCase();
  final right = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < left.length && j < right.length) {
    final leftIsDigit = _isDigit(left.codeUnitAt(i));
    final rightIsDigit = _isDigit(right.codeUnitAt(j));
    if (leftIsDigit && rightIsDigit) {
      final leftEnd = _endOfDigits(left, i);
      final rightEnd = _endOfDigits(right, j);
      final byNumber = _compareDigitRuns(left, i, leftEnd, right, j, rightEnd);
      if (byNumber != 0) return byNumber;
      i = leftEnd;
      j = rightEnd;
      continue;
    }
    // 数字段排在非数字段之前：`Episode 2` 排在 `Episode Pilot` 前面。
    if (leftIsDigit != rightIsDigit) return leftIsDigit ? -1 : 1;
    final leftCode = left.codeUnitAt(i);
    final rightCode = right.codeUnitAt(j);
    if (leftCode != rightCode) return leftCode < rightCode ? -1 : 1;
    i++;
    j++;
  }
  if (i < left.length) return 1;
  if (j < right.length) return -1;
  return 0;
}

/// 无集号的条目（剧场版/特典/合辑）统一用这个大数当集号，排在所有带集号的之后。
///
/// 选「大数」而不是在比较里写 null 分支，是为了让排序键始终是纯数值元组，
/// 比较逻辑只有一条路径。
const int _noEpisodeRank = 1 << 30;

/// 剧集排序：先 (season ?? 0, episode ?? 大数)，再标题自然序，最后原始文件名。
///
/// 「无集号排最后」是刻意的：第 12 集之后该出现的是第 13 集，而不是剧场版；
/// 剧场版、NCOP/NCED、总集篇这类没有集号的条目统一沉底。
int compareEpisodes({
  required ParsedMediaName a,
  required String nameA,
  required ParsedMediaName b,
  required String nameB,
}) {
  final bySeason = (a.season ?? 0).compareTo(b.season ?? 0);
  if (bySeason != 0) return bySeason;

  final byEpisode = (a.episode ?? _noEpisodeRank)
      .compareTo(b.episode ?? _noEpisodeRank);
  if (byEpisode != 0) return byEpisode;

  final byTitle = compareNatural(a.title, b.title);
  if (byTitle != 0) return byTitle;

  return compareNatural(nameA, nameB);
}

/// 视频扩展名白名单（规格 §5.3）。不认识的扩展名一律不当视频 ——
/// 与其猜错把 `.part`、`.iso` 塞进列表，不如让用户自己加。
const Set<String> _videoExtensions = <String>{
  'mp4',
  'mkv',
  'webm',
  'avi',
  'mov',
  'm4v',
  'ts',
  'm2ts',
  'flv',
  'wmv',
  'mpg',
  'mpeg',
  'ogv',
};

/// 音频扩展名白名单：能播，但不做专门的 UI。
const Set<String> _audioExtensions = <String>{
  'mp3',
  'flac',
  'aac',
  'm4a',
  'ogg',
  'opus',
  'wav',
};

/// 外挂字幕扩展名白名单。
const Set<String> _subtitleExtensions = <String>{'srt', 'ass', 'ssa', 'vtt', 'sub'};

/// 是否视频文件（按扩展名，大小写不敏感；没有扩展名的一律 false）。
bool isVideoFileName(String fileName) =>
    _videoExtensions.contains(_extensionOf(fileName));

/// 是否音频文件（按扩展名，大小写不敏感）。
bool isAudioFileName(String fileName) =>
    _audioExtensions.contains(_extensionOf(fileName));

/// 是否外挂字幕文件（按扩展名，大小写不敏感）。
bool isSubtitleFileName(String fileName) =>
    _subtitleExtensions.contains(_extensionOf(fileName));

/// 语言标签表：文件名里以短标签形式出现的语言标识。
const Map<String, String> _languageTags = <String, String>{
  // 简中
  'zh': 'zh',
  'chs': 'zh',
  'chi': 'zh',
  'zhs': 'zh',
  'sc': 'zh',
  'cn': 'zh',
  'gb': 'zh',
  'simp': 'zh',
  // 繁中
  'cht': 'zh-Hant',
  'zht': 'zh-Hant',
  'tc': 'zh-Hant',
  'tw': 'zh-Hant',
  'hk': 'zh-Hant',
  'big5': 'zh-Hant',
  // 日文 / 英文
  'ja': 'ja',
  'jp': 'ja',
  'jpn': 'ja',
  'jap': 'ja',
  'en': 'en',
  'eng': 'en',
};

/// 复合语言标签（`zh-Hant`、`zh-cn` …）必须整体判，否则会被拆成 `zh` + `hant`。
final RegExp _traditionalCompoundPattern = RegExp(r'zh[-_.]?(?:hant|tw|hk)|hant|big5');

final RegExp _simplifiedCompoundPattern = RegExp(r'zh[-_.]?(?:hans|cn|sg)|hans');

/// 按 `.`/`_`/`-`/空白/括号切分词。
final RegExp _tokenSplitPattern = RegExp(r'[._\-\s\[\]\(\)【】{}]+');

/// 从字幕文件名推断语言标签；推断不到返回 null。
///
/// 判定顺序有讲究：先看复合标签（`zh-hant` 不能被拆成 `zh`），再看中文词
/// （`繁体中文` 里两边的词都在，繁体优先），最后才从右往左扫短标签 ——
/// 语言标签按惯例贴在扩展名前面，所以最右边的那个才是语言。
String? subtitleLanguageFor(String fileName) {
  final base = _stripExtension(fileName).toLowerCase();
  if (base.isEmpty) return null;

  if (_traditionalCompoundPattern.hasMatch(base)) return 'zh-Hant';
  if (_simplifiedCompoundPattern.hasMatch(base)) return 'zh';

  if (base.contains('繁体') || base.contains('繁中')) return 'zh-Hant';
  if (base.contains('简体') ||
      base.contains('简中') ||
      base.contains('中文') ||
      base.contains('中字') ||
      base.contains('国语')) {
    return 'zh';
  }
  if (base.contains('日文') || base.contains('日语') || base.contains('日語')) {
    return 'ja';
  }
  if (base.contains('英文') || base.contains('英语') || base.contains('英語')) {
    return 'en';
  }

  final tokens = base.split(_tokenSplitPattern);
  for (final token in tokens.reversed) {
    final language = _languageTags[token];
    if (language != null) return language;
  }
  return null;
}

/// 语言标签的中文显示名（播放器字幕菜单用）。
const Map<String, String> _languageDisplayNames = <String, String>{
  'zh': '简体',
  'zh-Hant': '繁体',
  'ja': '日文',
  'en': '英文',
};

/// 字幕显示标签（播放器字幕菜单）。例如 `影片名.zh.ass` → `简体`。
/// 推断不到语言时返回去掉扩展名的文件名，至少还认得出来是哪个文件。
String subtitleLabelFor(String fileName) {
  final language = subtitleLanguageFor(fileName);
  if (language != null) return _languageDisplayNames[language] ?? language;
  final base = _stripExtension(fileName.trim());
  return base.isEmpty ? fileName.trim() : base;
}

/// 后缀分隔符：`movie.zh.ass`、`movie_zh.srt`、`movie-zh.srt`、`movie zh.ass`。
const Set<String> _suffixSeparators = <String>{'.', '_', '-', ' '};

/// 语言/标签后缀的长度上限。语言标签都很短（`.zh`、`.zh-Hans`、`.简体`），
/// 超过这个长度更像是另一部作品的名字（`movie.behind.the.scenes.srt`）。
const int _maxSubtitleSuffixLength = 16;

/// 字幕配对：给定一个视频文件名和同目录的其它文件名，返回与它同 basename 的
/// 字幕（保持输入顺序，只返回 [isSubtitleFileName] 为真的项）。
///
/// 「同 basename」= 字幕去掉扩展名后，要么等于视频 basename（`movie.mkv` +
/// `movie.srt`），要么是「视频 basename + 分隔符 + 语言/标签后缀」
/// （`movie.zh.ass`、`movie.chs.srt`、`movie.简体.ass`）。
/// `movie2.srt` 不是 `movie.mkv` 的字幕 —— 后面缺分隔符，判为另一部片。
List<String> subtitlesForVideo({
  required String videoFileName,
  required Iterable<String> directoryFileNames,
}) {
  final videoBase = _stripExtension(videoFileName.trim()).toLowerCase();
  if (videoBase.isEmpty) return <String>[];

  final matched = <String>[];
  for (final candidate in directoryFileNames) {
    if (!isSubtitleFileName(candidate)) continue;
    final candidateBase = _stripExtension(candidate.trim()).toLowerCase();
    if (_isSubtitleOf(videoBase, candidateBase)) matched.add(candidate);
  }
  return matched;
}

bool _isSubtitleOf(String videoBase, String subtitleBase) {
  if (subtitleBase == videoBase) return true;
  if (!subtitleBase.startsWith(videoBase)) return false;
  final suffix = subtitleBase.substring(videoBase.length);
  // 中间必须有分隔符：`movie2` / `movies` 都不算 `movie` 的字幕。
  if (!_suffixSeparators.contains(suffix[0])) return false;
  return suffix.length <= _maxSubtitleSuffixLength;
}

// ——————————————————————————————— 内部实现 ———————————————————————————————

/// 把命中的区间从文本里抠掉。先从后往前删，避免前面的删除让后面的下标漂移。
String _removeSpans(String text, List<_EpisodeMatch> spans) {
  if (spans.isEmpty) return text;
  // 先合并重叠区间：`Show Season 2` 会同时命中「尾部集号 = 2」和「Season 2 是季号」，
  // 两个区间套在一起。分开删的话，先删掉的 [11,12) 会让边界收缩，把包着它的
  // [5,13) 判成失效而跳过，"Season" 就留在标题里了。
  final ordered = List<_EpisodeMatch>.of(spans)
    ..sort((a, b) => a.start.compareTo(b.start));
  final merged = <List<int>>[];
  for (final span in ordered) {
    if (merged.isNotEmpty && span.start <= merged.last[1]) {
      if (span.end > merged.last[1]) merged.last[1] = span.end;
      continue;
    }
    merged.add(<int>[span.start, span.end]);
  }
  var result = text;
  for (final range in merged.reversed) {
    final start = range[0].clamp(0, result.length);
    final end = range[1].clamp(start, result.length);
    result = '${result.substring(0, start)} ${result.substring(end)}';
  }
  return result;
}

/// 标题的最终形态：清噪声 → 分隔符归一 → 拆掉整体包裹的括号。
String _finalizeTitle({required String withoutEpisode, required String base}) {
  final cleaned = _unwrapBrackets(_normalizeSeparators(_removeNoise(withoutEpisode)));
  if (cleaned.isNotEmpty) return cleaned;

  // 走到这里说明整个名字都是噪声（`1080p.mkv`），或者被当字幕组名全部吃掉
  // （`[银魂] 第001话.mkv`）。宁可保留一份粗糙的名字，也不要给 UI 一个空标题。
  final fallback = _unwrapBrackets(_normalizeSeparators(withoutEpisode));
  if (fallback.isNotEmpty) return fallback;
  return _unwrapBrackets(_normalizeSeparators(base));
}

String _removeNoise(String text) {
  var result = text.replaceAllMapped(
    _bracketBlockPattern,
    (match) => _isNoiseBracket(match) ? ' ' : match.group(0)!,
  );
  result = result.replaceAll(_resolutionPattern, ' ');
  result = result.replaceAll(_noiseTokenPattern, ' ');
  result = result.replaceAll(_noiseTagPattern, ' ');
  return result.replaceAll(_emptyBracketPattern, ' ');
}

bool _isNoiseBracket(Match match) {
  final content = match.group(1) ?? '';
  if (content.isEmpty) return true;
  if (_crcPattern.hasMatch(content)) return true;
  if (_bracketYearPattern.hasMatch(content)) return true;
  if (_noiseTokenPattern.hasMatch(content)) return true;
  if (_bracketTagPattern.hasMatch(content)) return true;
  // 开头的第一个方括号块：粉丝压制约定里那是字幕组名。
  if (match.start == 0 &&
      !content.contains(' ') &&
      content.length <= _maxLeadingGroupLength) {
    return true;
  }
  return false;
}

/// 分隔符归一：`_`、`.`、`-`、连续空白 → 单个空格；结果两端无空格、无连续空格。
///
/// 代价是 `Spider-Man` 会变成 `Spider Man` —— 对以「作品名 + 集号」为主的
/// 本地库来说，把 `Dragon-Ball-Z-001` 切干净比保住连字符更值。
String _normalizeSeparators(String text) =>
    text.replaceAll(_separatorPattern, ' ').trim();

/// 拆掉整体包裹的一对括号：`[银魂]` → `银魂`；`[A] [B]` 不动。
String _unwrapBrackets(String text) {
  if (text.length < 2) return text;
  const closing = <String, String>{'[': ']', '(': ')', '{': '}', '【': '】'};
  final close = closing[text[0]];
  if (close == null || !text.endsWith(close)) return text;
  final inner = text.substring(1, text.length - 1);
  if (inner.contains(close) || inner.contains(text[0])) return text;
  return inner.trim();
}

/// 去掉最后一个「扩展名」。只认字母开头的短段（见 [_extensionPattern]），
/// 且不去动形如 `.mkv` 这种整名都是扩展名的隐藏式命名。
String _stripExtension(String fileName) {
  final name = fileName.trim();
  final match = _extensionPattern.firstMatch(name);
  if (match == null) return name;
  final base = name.substring(0, match.start);
  return base.isEmpty ? name : base;
}

/// 小写扩展名；没有扩展名或形如 `.mkv` 时返回空串。
String _extensionOf(String fileName) {
  final name = fileName.trim();
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// 全角数字/字母/括号/空格 → 半角，让 `Ｓ０１Ｅ０２` 也能命中规则。
String _toHalfWidth(String text) {
  return text.replaceAllMapped(_fullWidthPattern, (match) {
    final code = match.group(0)!.codeUnitAt(0);
    if (code == 0x3000) return ' ';
    if (code >= 0xFF10 && code <= 0xFF19) {
      return String.fromCharCode(code - 0xFF10 + 0x30);
    }
    if (code >= 0xFF21 && code <= 0xFF3A) {
      return String.fromCharCode(code - 0xFF21 + 0x41);
    }
    if (code >= 0xFF41 && code <= 0xFF5A) {
      return String.fromCharCode(code - 0xFF41 + 0x61);
    }
    return _fullWidthReplacements[code] ?? match.group(0)!;
  });
}

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

int _endOfDigits(String text, int start) {
  var end = start;
  while (end < text.length && _isDigit(text.codeUnitAt(end))) {
    end++;
  }
  return end;
}

/// 比较两段数字：先跳前导零，再比位数（位数少的一定小），最后逐位比。
///
/// 不用 `int.parse` —— 文件名里出现几十位「数字」时它不该崩，也不该溢出。
int _compareDigitRuns(
  String a,
  int aStart,
  int aEnd,
  String b,
  int bStart,
  int bEnd,
) {
  var aIndex = aStart;
  var bIndex = bStart;
  // 至少保留一位，避免跳成空数字段。
  while (aIndex < aEnd - 1 && a.codeUnitAt(aIndex) == 0x30) {
    aIndex++;
  }
  while (bIndex < bEnd - 1 && b.codeUnitAt(bIndex) == 0x30) {
    bIndex++;
  }
  final aLength = aEnd - aIndex;
  final bLength = bEnd - bIndex;
  if (aLength != bLength) return aLength < bLength ? -1 : 1;
  for (var offset = 0; offset < aLength; offset++) {
    final aCode = a.codeUnitAt(aIndex + offset);
    final bCode = b.codeUnitAt(bIndex + offset);
    if (aCode != bCode) return aCode < bCode ? -1 : 1;
  }
  return 0;
}
