/// 本地库扫描：把「一个目录里的扁平文件列表」变成按剧集排好序的 [LocalMediaItem]。
///
/// 对应设计文档 docs/superpowers/specs/2026-09-30-local-playback-design.md
/// §5.3（解析与排序）、§9（异常与兼容）、§11（扫描分批）。
///
/// 分工是刻意拆开的：本文件只做**纯逻辑**（分组、过滤、字幕配对、排序、截断），
/// 「怎么把一个目录读成扁平文件列表」交给 [LocalDirectoryWalker] ——
/// Windows 用 dart:io（`DartIoDirectoryWalker`），Android 用 SAF 桥，
/// 测试用 [InMemoryDirectoryWalker]。这样排序与配对规则可以完全脱离文件系统单测。
///
/// 一条硬约束：扫描器**不拼路径字符串**。`location` 与 `directoryKey` 都由 walker 给出，
/// 本文件只做原样搬运 —— Windows 是绝对路径、Android 是 document uri，
/// 扫描器不该知道两者的区别（规格 §9：不做 URL 编码转换）。
library;

import 'dart:io';

import 'local_episode_parser.dart';
import 'local_models.dart';

/// 目录里的一条文件。位置既可能是 Windows 绝对路径，也可能是 Android document uri。
///
/// 这是平台无关的中间结构：只要求 walker 给出「文件名 + 位置 + 分组键 + 元数据」，
/// 扫描器据此产出 [LocalMediaItem]。
class LocalFileEntry {
  const LocalFileEntry({
    required this.location,
    required this.name,
    required this.directoryKey,
    required this.size,
    this.modifiedAt,
  });

  /// Windows: 绝对路径；Android: document uri。
  final String location;

  /// 含扩展名的文件名。解析与字幕配对只用它，不用完整位置。
  final String name;

  /// 同目录分组键（Windows: 目录绝对路径；Android: 父 document uri）。
  final String directoryKey;

  /// 字节数；取不到时为 0。
  final int size;

  /// 文件修改时间（epoch ms），取不到为 null。
  final int? modifiedAt;

  @override
  String toString() => 'LocalFileEntry($name @ $directoryKey, $size bytes)';
}

/// 目录遍历的平台抽象：Windows 用 dart:io，Android 用 SAF 桥，测试用内存假实现。
///
/// 实现方负责**递归**并把目录展开成扁平的文件列表；返回顺序无关紧要
/// （扫描器会按目录分组后统一排序），但同一个 `directoryKey` 必须对应同一个目录。
abstract interface class LocalDirectoryWalker {
  /// 递归遍历 [root]，返回其中所有文件（**不筛扩展名**：跳过计数由扫描器做）。
  ///
  /// [onProgress] 用于 UI 显示「已发现 N 个文件」，按实现方自己的节奏调用
  /// （`DartIoDirectoryWalker` 是每 200 个文件一次）。
  ///
  /// 抛异常表示「整次扫描失败」；单个子目录读不到应当自己跳过并计数，
  /// 不要整体失败（规格 §9）。
  Future<List<LocalFileEntry>> walk(
    String root, {
    void Function(int found)? onProgress,
  });
}

/// walker 自己记账的「被跳过条目数」上报口。
///
/// [LocalDirectoryWalker.walk] 的返回类型是**冻结的**（只有文件列表），
/// 被跳过的长路径/不可读目录不会出现在列表里，扫描器无从得知，只能由 walker
/// 自己计数后通过这个接口上报（规格 §9：超长路径「跳过并计数提示」）。
///
/// Android 桥将来遇到 `SecurityException` 时同样实现这个接口即可，
/// 扫描器一行都不用改。
abstract interface class LocalWalkSkipReport {
  /// 上一次 [LocalDirectoryWalker.walk] 中因长路径/不可读而被跳过的条目数。
  ///
  /// 每次 [LocalDirectoryWalker.walk] 开始时必须清零。
  int get skippedDuringWalk;
}

/// 一次扫描的结果。
class LocalScanResult {
  const LocalScanResult({
    required this.items,
    this.skipped = 0,
    this.truncated = false,
    this.warning,
  });

  /// 已按剧集顺序排好（下标即 episodeIndex，规格 §5.4）。
  final List<LocalMediaItem> items;

  /// 跳过的文件数：既不是媒体也不是字幕的 + walk 内被跳过的（长路径、读不到的目录）。
  ///
  /// 注意**不含**被 [LocalLibraryScanner.maxItems] 截断掉的媒体文件 ——
  /// 那部分由 [truncated] 表达，UI 的文案是两回事。
  final int skipped;

  /// 命中 maxItems 上限被截断。
  final bool truncated;

  /// 给 UI 的提示文案：扫描失败、被截断、什么都没扫到时才有值，其余为 null。
  final String? warning;

  @override
  String toString() => 'LocalScanResult(items: ${items.length}, '
      'skipped: $skipped, truncated: $truncated, warning: $warning)';
}

/// 本地库扫描器。
class LocalLibraryScanner {
  LocalLibraryScanner({
    required this.walker,
    bool? windows,
    this.maxItems = 20000,
  }) : windows = windows ?? Platform.isWindows;

  /// 目录遍历实现（平台相关；测试注入内存假实现）。
  final LocalDirectoryWalker walker;

  /// 是否按 Windows 语义扫描。默认 [Platform.isWindows]。
  ///
  /// 只影响给 UI 的提示文案（「文件夹」/「位置」）以及需要去重时的
  /// [localDedupeKey] 调用 —— 扫描器不因此拼任何路径。
  final bool windows;

  /// 单次扫描保留的媒体条目上限（规格 §11：> 20000 个文件就提示换更小的目录）。
  final int maxItems;

  /// 扫描 [root]，产出按剧集排序的条目。
  ///
  /// [libraryId] 原样写进每个 [LocalMediaItem.libraryId]。[onProgress] 透传给
  /// [LocalDirectoryWalker.walk]，用于「已发现 N 个文件」。
  ///
  /// 失败与降级：
  /// - walk 抛异常 → 返回空结果 + `warning`（**不含完整路径**，规格 §10），不向上抛。
  /// - 单个子目录读不到 → 由 walker 跳过并计数，已扫到的条目照常返回。
  /// - 媒体数超过 [maxItems] → 排序后截断，`truncated: true`。
  Future<LocalScanResult> scan({
    required String libraryId,
    required String root,
    void Function(int count)? onProgress,
  }) async {
    final List<LocalFileEntry> entries;
    try {
      entries = await walker.walk(root, onProgress: onProgress);
    } catch (error) {
      // 整次扫描失败也别把异常抛给 UI，更不要把异常原文（可能含完整路径）塞进提示。
      return LocalScanResult(
        items: const <LocalMediaItem>[],
        warning: '扫描失败：${_summarizeScanError(error)}',
      );
    }

    // walk 内部跳过的条目（长路径/不可读目录）不在返回列表里，只能问 walker 自己。
    // 这里必须声明成 Object：LocalWalkSkipReport 与 LocalDirectoryWalker 没有继承关系，
    // 声明成 LocalDirectoryWalker 时 `is` 无法做类型提升，getter 会报 undefined_getter。
    final Object activeWalker = walker;
    final int walkSkipped = activeWalker is LocalWalkSkipReport
        ? activeWalker.skippedDuringWalk
        : 0;
    var skipped = walkSkipped;

    // 1) 按 directoryKey 分组：字幕只和**同一个目录**里的媒体配对，跨目录一律不配。
    final Map<String, _DirectoryIndex> directories =
        <String, _DirectoryIndex>{};
    for (final LocalFileEntry entry in entries) {
      directories.putIfAbsent(entry.directoryKey, _DirectoryIndex.new).add(entry);
    }

    // 2) 目录内分流：媒体进候选；既不是媒体也不是字幕的计入 skipped。
    final List<_MediaCandidate> candidates = <_MediaCandidate>[];
    for (final _DirectoryIndex index in directories.values) {
      for (final LocalFileEntry entry in index.entries) {
        if (isVideoFileName(entry.name) || isAudioFileName(entry.name)) {
          candidates.add(
            _MediaCandidate(
              entry: entry,
              parsed: parseMediaFileName(entry.name),
            ),
          );
        } else if (!isSubtitleFileName(entry.name)) {
          skipped++;
        }
      }
    }

    // 3) 排序键全部来自解析结果，不碰 location —— Android 的 uri 没有字典序意义。
    //    同一文件名（同名的两部片在不同目录）时再用 location 兜底成全序。
    candidates.sort((left, right) {
      final int byEpisode = compareEpisodes(
        a: left.parsed,
        nameA: left.entry.name,
        b: right.parsed,
        nameB: right.entry.name,
      );
      if (byEpisode != 0) return byEpisode;
      return compareNatural(left.entry.location, right.entry.location);
    });

    // 4) 截断：先排序再截，「前 N 个」是剧集意义上的前 N 个，而不是先扫到的 N 个。
    final int limit = maxItems < 0 ? 0 : maxItems;
    final bool truncated = candidates.length > limit;
    final List<_MediaCandidate> kept =
        truncated ? candidates.sublist(0, limit) : candidates;

    // 5) 造条目。addedAt 整个 scan 只取一次 now：同一次扫描的条目时间一致，
    //    测试可断言相等，UI 也能把它当一批处理。
    final int addedAt = DateTime.now().millisecondsSinceEpoch;
    final List<LocalMediaItem> items = <LocalMediaItem>[
      for (final _MediaCandidate candidate in kept)
        _buildItem(
          candidate: candidate,
          index: directories[candidate.entry.directoryKey],
          libraryId: libraryId,
          addedAt: addedAt,
        ),
    ];

    final String? warning;
    if (truncated) {
      warning = '目录太大，只扫描了前 $limit 个文件（共 ${candidates.length} 个）。';
    } else if (items.isEmpty) {
      warning = windows
          ? '这个文件夹里没有找到可播放的媒体文件。'
          : '这个位置里没有找到可播放的媒体文件。';
    } else {
      warning = null;
    }

    return LocalScanResult(
      items: items,
      skipped: skipped,
      truncated: truncated,
      warning: warning,
    );
  }
}

/// 测试与降级用的内存实现：直接把构造时给的条目交给扫描器。
///
/// [entries] 是**扁平列表**（不是按目录分好的 Map）：分组完全由每条自己的
/// [LocalFileEntry.directoryKey] 决定，所以「隔壁目录的文件名不该配到本目录」
/// 这类用例只要给不同的 directoryKey 就能表达，不需要真的建目录树。
/// 条目按给定顺序返回，[LocalDirectoryWalker.walk] 的 `root` 参数被忽略。
///
/// 给了 [error] 就直接抛（模拟 Android 桥未就绪 / 整次扫描失败），
/// 用来验证扫描器的降级路径。不给则按 [entries] 正常返回并调用一次 `onProgress`。
class InMemoryDirectoryWalker implements LocalDirectoryWalker {
  InMemoryDirectoryWalker(this.entries, {this.error});

  final List<LocalFileEntry> entries;

  /// 非 null 时 [walk] 抛出它（模拟扫描失败）。
  final Object? error;

  @override
  Future<List<LocalFileEntry>> walk(
    String root, {
    void Function(int found)? onProgress,
  }) async {
    final Object? failure = error;
    if (failure != null) throw failure;
    final List<LocalFileEntry> found = List<LocalFileEntry>.of(entries);
    onProgress?.call(found.length);
    return found;
  }
}

// ———————————————————————————— 内部实现 ————————————————————————————

/// 候选：一条媒体文件 + 它的解析结果（排序与建条目都要用）。
class _MediaCandidate {
  const _MediaCandidate({required this.entry, required this.parsed});

  final LocalFileEntry entry;
  final ParsedMediaName parsed;
}

/// 一个目录的索引：条目、文件名列表、文件名 → 条目。
///
/// 字幕配对拿到的是**文件名**，要换成 `location` 才能造 [LocalSubtitle]，
/// 所以这里同时留一份文件名到条目的映射。
class _DirectoryIndex {
  final List<LocalFileEntry> entries = <LocalFileEntry>[];
  final List<String> names = <String>[];
  final Map<String, LocalFileEntry> byName = <String, LocalFileEntry>{};

  void add(LocalFileEntry entry) {
    entries.add(entry);
    names.add(entry.name);
    // 同名条目（Android 上不同目录项可能显示名相同）取先出现的那个，
    // 保证字幕配对结果稳定，不随遍历顺序抖动。
    byName.putIfAbsent(entry.name, () => entry);
  }
}

LocalMediaItem _buildItem({
  required _MediaCandidate candidate,
  required _DirectoryIndex? index,
  required String libraryId,
  required int addedAt,
}) {
  final LocalFileEntry entry = candidate.entry;
  return LocalMediaItem(
    id: newLocalId(),
    libraryId: libraryId,
    // 解析器兜了一层「全是噪声」的情况，这里再兜一层空标题，绝不给 UI 空标题。
    title: candidate.parsed.title.isEmpty
        ? _titleWithoutExtension(entry.name)
        : candidate.parsed.title,
    // 原样搬运：不做编码、不做规范化、不补分隔符。
    location: entry.location,
    season: candidate.parsed.season,
    episode: candidate.parsed.episode,
    sizeBytes: entry.size,
    modifiedAt: entry.modifiedAt,
    // 时长与缩略图由 M2 探测后回填。
    durationMs: null,
    thumbPath: null,
    subtitles: _subtitlesFor(entry: entry, index: index),
    addedAt: addedAt,
    // lastPlayedAt 留 null：保留旧值由 store 负责，不是扫描器的职责。
  );
}

/// 本文件的 [LocalFileEntry] 对应的外挂字幕。
///
/// [subtitlesForVideo] 返回的是**同目录**的候选文件名（保持输入顺序，字幕菜单顺序稳定）；
/// 这里把文件名换回位置 —— 换不到就跳过，绝不凭文件名拼一个位置出来。
List<LocalSubtitle> _subtitlesFor({
  required LocalFileEntry entry,
  required _DirectoryIndex? index,
}) {
  if (index == null || index.names.isEmpty) return const <LocalSubtitle>[];
  final List<LocalSubtitle> subtitles = <LocalSubtitle>[];
  final List<String> matched = subtitlesForVideo(
    videoFileName: entry.name,
    directoryFileNames: index.names,
  );
  for (final String name in matched) {
    final LocalFileEntry? subtitleEntry = index.byName[name];
    if (subtitleEntry == null) continue;
    subtitles.add(
      LocalSubtitle(
        location: subtitleEntry.location,
        label: subtitleLabelFor(name),
        language: subtitleLanguageFor(name),
      ),
    );
  }
  return subtitles;
}

/// 标题兜底：去掉最后一个扩展名的文件名（解析器给不出标题时才用）。
String _titleWithoutExtension(String fileName) {
  final String name = fileName.trim();
  final int dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  return name.substring(0, dot);
}

/// 把异常压成一句能进 UI 的摘要，并抹掉其中的路径（规格 §10：不打印完整用户路径）。
String _summarizeScanError(Object error) {
  final String raw;
  if (error is FileSystemException) {
    // FileSystemException.message 本身不含路径（路径在 path 字段里，toString 才带上）。
    final String message = error.message.trim();
    if (message.isNotEmpty) {
      raw = message;
    } else {
      raw = error.osError?.message ?? '文件系统错误';
    }
  } else {
    raw = error.toString();
  }
  final String redacted = _redactPathLike(raw);
  return redacted.isEmpty ? '未知错误' : redacted;
}

/// 盘符路径 / uri / POSIX 绝对路径 → 占位符。
///
/// 泛型异常（`Exception('读取 F:\\Anime\\Show 失败')`）的原文里可能带完整路径，
/// 而目录名可能就是用户的真实姓名，所以一律抹掉，只留「哪里出了什么事」。
String _redactPathLike(String text) => text
    .replaceAll(RegExp(r'[A-Za-z][A-Za-z0-9+.\-]*://[^\s]*'), '<位置>')
    .replaceAll(RegExp(r'[A-Za-z]:[\\/][^\s]*'), '<路径>')
    .replaceAll(RegExp(r'/(?:[^\s/]+/)+[^\s/]*'), '<路径>')
    .trim();
