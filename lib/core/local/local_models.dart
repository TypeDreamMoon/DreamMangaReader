/// 本地播放的数据模型。纯数据结构 + 纯函数,不依赖 Flutter,
/// 也不碰文件系统(存在性检查由平台层在运行时推导,见 [LocalMediaItem])。
///
/// 设计见 docs/superpowers/specs/2026-09-30-local-playback-design.md §5.1。
library;

import 'dart:math';

/// 本地库的来源:用户授权的目录,或单独挑的几个文件。
enum LocalLibraryKind { folder, file }

/// 本地内容在“源”维度上的标识。
///
/// 本地条目没有真实 source,但进度、历史都挂在 `sourceId` 上
/// (`AnimeLibraryStore.saveProgress`),所以用一个保留 id 占位。
/// `'local'` 不会与任何真实源 id 冲突(source id 由用户命名,仓库里没有这个值)。
abstract final class LocalSource {
  static const String id = 'local';
}

/// 外挂字幕:同目录同名文件,播放时作为 [SubtitleAsset] 交给播放器。
class LocalSubtitle {
  const LocalSubtitle({
    required this.location,
    this.label = '',
    this.language,
  });

  /// Windows 绝对路径,或 Android document uri。
  final String location;

  /// 展示名,如 "简体中文" / "zh";空则由 UI 兜底。
  final String label;

  /// BCP-47 语言码,可空。
  final String? language;

  Map<String, Object?> toJson() => {
        'location': location,
        'label': label,
        if (language != null) 'language': language,
      };

  factory LocalSubtitle.fromJson(Map<Object?, Object?> json) => LocalSubtitle(
        location: _stringField(json, 'location'),
        label: _stringField(json, 'label'),
        language: json['language'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is LocalSubtitle &&
      other.location == location &&
      other.label == label &&
      other.language == language;

  @override
  int get hashCode => Object.hash(location, label, language);

  @override
  String toString() => 'LocalSubtitle($label, $location)';
}

/// 一个可播放的本地条目(视频/音频文件)。
class LocalMediaItem {
  const LocalMediaItem({
    required this.id,
    required this.libraryId,
    required this.title,
    required this.location,
    this.season,
    this.episode,
    this.sizeBytes = 0,
    this.modifiedAt,
    this.durationMs,
    this.subtitles = const [],
    this.thumbPath,
    this.customTitle,
    this.addedAt = 0,
    this.lastPlayedAt,
  });

  /// uuid,只作内部键与进度的 `episodeId`;跨设备/跨次启动不变。
  final String id;
  final String libraryId;

  /// 清理后的展示标题(去扩展名、去分辨率等噪声),由文件名解析器给出。
  final String title;

  /// 用户自己起的名字;为空表示没改过(规格 §5.6)。
  ///
  /// 与 [title] **分开存**是有意的:重扫会按解析结果刷新 [title],如果直接改
  /// [title],用户起的名字下次重扫就被冲掉了。
  final String? customTitle;

  /// Windows 绝对路径,或 Android document uri。
  final String location;

  final int? season;
  final int? episode;
  final int sizeBytes;

  /// 文件修改时间(epoch ms)。扫描增量比对用 size + mtime,可空。
  final int? modifiedAt;

  /// 时长由 M2 探测后回填,M1 允许为空。
  final int? durationMs;

  final List<LocalSubtitle> subtitles;

  /// M2 抽帧缩略图的相对文件名。
  final String? thumbPath;

  final int addedAt;

  /// 最近一次播放时间,**只用于“最近播放”排序**。
  /// 真正的续播位置以 `AnimeLibraryStore` 的历史为准(规格 §5.4)。
  final int? lastPlayedAt;

  /// 去重键:同一文件重复添加时据此跳过。
  /// Windows 用规范化绝对路径(大小写归一),Android 用 document uri。
  String dedupeKey({required bool windows}) =>
      localDedupeKey(location, windows: windows);

  /// 界面上该显示的名字:用户改过就用用户的,否则用解析出来的。
  ///
  /// 空白的 [customTitle](手改过索引、或老数据)当没改过处理。
  String get displayTitle {
    final custom = customTitle?.trim() ?? '';
    return custom.isEmpty ? title : custom;
  }

  LocalMediaItem copyWith({
    String? title,
    String? location,
    int? season,
    int? episode,
    int? sizeBytes,
    int? modifiedAt,
    int? durationMs,
    List<LocalSubtitle>? subtitles,
    String? thumbPath,
    String? customTitle,
    bool clearCustomTitle = false,
    int? lastPlayedAt,
  }) =>
      LocalMediaItem(
        id: id,
        libraryId: libraryId,
        title: title ?? this.title,
        location: location ?? this.location,
        season: season ?? this.season,
        episode: episode ?? this.episode,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        durationMs: durationMs ?? this.durationMs,
        subtitles: subtitles ?? this.subtitles,
        thumbPath: thumbPath ?? this.thumbPath,
        customTitle: clearCustomTitle ? null : (customTitle ?? this.customTitle),
        addedAt: addedAt,
        lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'libraryId': libraryId,
        'title': title,
        'location': location,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
        'sizeBytes': sizeBytes,
        if (modifiedAt != null) 'modifiedAt': modifiedAt,
        if (durationMs != null) 'durationMs': durationMs,
        if (subtitles.isNotEmpty)
          'subtitles': [for (final s in subtitles) s.toJson()],
        if (thumbPath != null) 'thumbPath': thumbPath,
        if ((customTitle?.trim() ?? '').isNotEmpty) 'customTitle': customTitle,
        'addedAt': addedAt,
        if (lastPlayedAt != null) 'lastPlayedAt': lastPlayedAt,
      };

  /// 读索引时对缺失字段一律取默认值(向后兼容,规格 §9)。
  factory LocalMediaItem.fromJson(Map<Object?, Object?> json) => LocalMediaItem(
        id: _stringField(json, 'id'),
        libraryId: _stringField(json, 'libraryId'),
        title: _stringField(json, 'title'),
        location: _stringField(json, 'location'),
        season: _intField(json, 'season'),
        episode: _intField(json, 'episode'),
        sizeBytes: _intField(json, 'sizeBytes') ?? 0,
        modifiedAt: _intField(json, 'modifiedAt'),
        durationMs: _intField(json, 'durationMs'),
        subtitles: _subtitlesFromJson(json['subtitles']),
        thumbPath: json['thumbPath'] as String?,
        customTitle: _optionalStringField(json, 'customTitle'),
        addedAt: _intField(json, 'addedAt') ?? 0,
        lastPlayedAt: _intField(json, 'lastPlayedAt'),
      );

  static List<LocalMediaItem> listFromJson(Object? value) => [
        for (final entry in (value as List?) ?? const [])
          if (entry is Map) LocalMediaItem.fromJson(entry),
      ];

  @override
  String toString() => 'LocalMediaItem($title, $location)';
}

/// 一个本地库:用户授权的目录,或一批单独挑选的文件。
class LocalLibrary {
  const LocalLibrary({
    required this.id,
    required this.name,
    required this.kind,
    this.path,
    this.treeUri,
    this.addedAt = 0,
    this.lastScannedAt = 0,
    this.coverThumb,
  });

  /// uuid。
  final String id;
  final String name;
  final LocalLibraryKind kind;

  /// Windows: 目录/文件所在目录的绝对路径(反斜杠)。
  final String? path;

  /// Android: SAF tree/document uri(已取持久读授权)。
  final String? treeUri;

  final int addedAt;
  final int lastScannedAt;

  /// 库封面缩略图(M2)。
  final String? coverThumb;

  /// 去重键:同一路径/treeUri 重复添加时据此跳过。
  String dedupeKey({required bool windows}) => localLibraryDedupeKey(
        path: path,
        treeUri: treeUri,
        windows: windows,
      );

  LocalLibrary copyWith({
    String? name,
    String? path,
    String? treeUri,
    int? lastScannedAt,
    String? coverThumb,
  }) =>
      LocalLibrary(
        id: id,
        name: name ?? this.name,
        kind: kind,
        path: path ?? this.path,
        treeUri: treeUri ?? this.treeUri,
        addedAt: addedAt,
        lastScannedAt: lastScannedAt ?? this.lastScannedAt,
        coverThumb: coverThumb ?? this.coverThumb,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        if (path != null) 'path': path,
        if (treeUri != null) 'treeUri': treeUri,
        'addedAt': addedAt,
        'lastScannedAt': lastScannedAt,
        if (coverThumb != null) 'coverThumb': coverThumb,
      };

  factory LocalLibrary.fromJson(Map<Object?, Object?> json) => LocalLibrary(
        id: _stringField(json, 'id'),
        name: _stringField(json, 'name'),
        kind: LocalLibraryKind.values.firstWhere(
          (value) => value.name == json['kind'],
          orElse: () => LocalLibraryKind.folder,
        ),
        path: json['path'] as String?,
        treeUri: json['treeUri'] as String?,
        addedAt: _intField(json, 'addedAt') ?? 0,
        lastScannedAt: _intField(json, 'lastScannedAt') ?? 0,
        coverThumb: json['coverThumb'] as String?,
      );

  @override
  String toString() => 'LocalLibrary($name, ${kind.name}, ${path ?? treeUri})';
}

/// 条目去重键。
///
/// Windows 路径大小写不敏感,比较时归一;Android 的 document uri 由系统保证唯一,
/// 原样使用。注意这里**不做 URL 编码转换**(规格 §9:索引入库前后都不转码)。
String localDedupeKey(String location, {required bool windows}) {
  final trimmed = location.trim();
  if (!windows) return trimmed;
  return trimmed.replaceAll('/', r'\').toLowerCase();
}

/// 库去重键:优先用 treeUri(Android),否则用 Windows 路径。
String localLibraryDedupeKey({
  String? path,
  String? treeUri,
  required bool windows,
}) {
  final anchor = treeUri?.trim();
  if (anchor != null && anchor.isNotEmpty) return anchor;
  return localDedupeKey(path ?? '', windows: windows);
}

/// 索引里落盘的库/条目名字:与 `DownloadStore._safe`、`AnimeDownloadStore`
/// 同一套硬化规则,防止路径穿越(规格 §10)。
String localSafeName(String name) =>
    name.replaceAll(_unsafeNamePattern, '_');

/// 路径硬化要替换掉的字符:非字母/数字/`_`/`.`/`-`。提到顶层复用,避免每次调用重建。
final RegExp _unsafeNamePattern = RegExp(r'[^A-Za-z0-9_.-]');

/// 生成一个 uuid v4 形式的本地 id。
///
/// 不引入 `uuid` 依赖:16 字节安全随机数按 RFC 4122 打上版本/变体位,
/// 拼成标准文本。id 只作内部键与进度的 `episodeId`,不需要全局唯一性证明。
String newLocalId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  final buffer = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) buffer.write('-');
    buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// 索引字段读取:旧索引可能缺字段、类型也可能不对(手改过的 json),所以字符串
/// 一律回落到空串、数字一律回落到 null,由各 `fromJson` 决定要不要再补 `?? 0`。
String _stringField(Map<Object?, Object?> json, String key) =>
    json[key] as String? ?? '';

/// 可选字符串字段:缺失、类型不对、只有空白都当「没有」。读回来顺手 trim,
/// 手改过索引里带空格的 `customTitle` 不该变成界面上一个带空格的名字。
String? _optionalStringField(Map<Object?, Object?> json, String key) {
  final value = (json[key] as String?)?.trim() ?? '';
  return value.isEmpty ? null : value;
}

int? _intField(Map<Object?, Object?> json, String key) =>
    (json[key] as num?)?.toInt();

/// 字幕数组:非列表按空处理,列表里的非 Map 元素跳过(与旧行为一致)。
List<LocalSubtitle> _subtitlesFromJson(Object? value) => [
      for (final entry in (value as List?) ?? const [])
        if (entry is Map) LocalSubtitle.fromJson(entry),
    ];

// --- 位置字符串工具 -------------------------------------------------------
//
// Windows 的反斜杠路径与 Android 的 SAF uri 在这里走同一套:先统一成 `/`,再按
// 段处理。**不做 URL 解码**(规格 §9),只有需要显示目录名时才解码(见
// [localParentDisplayName])。

/// 位置去掉末尾 `/` 并统一分隔符(Windows 路径与 SAF uri 都能过一遍)。
String _normalizedLocation(String location) {
  final normalized = location.replaceAll(r'\', '/');
  return normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
}

/// 从一个位置里取出展示名(Windows 反斜杠也认)。
String localLocationName(String location) {
  final trimmed = _normalizedLocation(location);
  final cut = trimmed.lastIndexOf('/');
  final name = cut < 0 ? trimmed : trimmed.substring(cut + 1);
  return name.isEmpty ? trimmed : name;
}

/// Windows 上取一个路径的父目录;没有父目录时返回它自己。
String localLocationParent(String location) {
  final trimmed = _normalizedLocation(location);
  final cut = trimmed.lastIndexOf('/');
  if (cut <= 0) return trimmed;
  return trimmed.substring(0, cut);
}

/// SAF 的 document/tree uri 前缀。
const String _contentUriPrefix = 'content://';

/// 位置所在**目录的键** —— 同一个目录下的文件给出同一个键(不用于展示,只用于
/// 判断「是不是一堆东西」)。
///
/// 两条路形态完全不同,所以要分开处理:
/// - Windows 之类的真实路径:分隔符就是 `/`(规范化过),取父目录;
/// - SAF:`content://…/document/primary%3AMovies%2Fx.mkv` —— 卷名 + 路径整段是
///   **一个**路径段(百分号编码的 `/` 不是分隔符),不先解码的话所有文件都会算出
///   同一个父目录 `…/document`。
String localParentKey(String location) {
  final normalized = _normalizedLocation(location);
  if (normalized.isEmpty) return '';
  if (normalized.startsWith(_contentUriPrefix)) {
    final segments = _safDocIdSegments(normalized);
    if (segments.isEmpty) return normalized;
    // 最后一段是文件本身;只有一段时这个 uri 指向的就是目录(比如 tree uri)。
    final folder = segments.length >= 2
        ? segments.sublist(0, segments.length - 1)
        : segments;
    return folder.join('/');
  }
  final parent = localLocationParent(normalized);
  return parent.isEmpty ? normalized : parent;
}

/// 位置所在目录的**展示名**:Windows 取最后一段目录名;SAF 取解码后 docId 里的
/// 目录段(`primary%3AMovies%2Fx.mkv` → `Movies`)。卷名(SD 卡号、`primary`)不是
/// 目录名,不进显示名。
///
/// 位置本身就是个裸名字(没有目录)、或拿不到目录名时返回空串(调用方自己兜底),
/// 绝不抛错。
String localParentDisplayName(String location) {
  final normalized = _normalizedLocation(location);
  final key = localParentKey(normalized);
  if (key.isEmpty || key == normalized) return '';
  // `primary:Media/Movies` / `C:/Media/Movies` 的冒号前都是「卷」,不是目录。
  final colon = key.indexOf(':');
  final withoutVolume = colon >= 0 ? key.substring(colon + 1) : key;
  final segments = [
    for (final segment in withoutVolume.split('/'))
      if (segment.trim().isNotEmpty) segment,
  ];
  return segments.isEmpty ? withoutVolume.trim() : segments.last.trim();
}

/// SAF docId 解码后的路径段:`primary%3AMedia%2FMovies%2Fx.mkv` →
/// `['primary:Media', 'Movies', 'x.mkv']`(卷名黏在第一段上)。
///
/// 解不开(手改过的 uri、半截编码)就用原样,至少不是个异常。
List<String> _safDocIdSegments(String location) {
  final docId = localLocationName(location);
  if (docId.isEmpty) return const [];
  var decoded = docId;
  try {
    decoded = Uri.decodeComponent(docId);
  } on Object {
    decoded = docId;
  }
  return [
    for (final segment in decoded.split('/'))
      if (segment.trim().isNotEmpty) segment,
  ];
}

// --- 「哪几条属于同一部剧」-------------------------------------------------

/// 剧名归一化后的匹配键:大小写、空白与常见分隔符都不参与比较。
///
/// 只用来**判断两条是不是同一部剧**,不用于展示,所以可以尽情报复性归一
/// (`Loki` / `loki` / `LOKI-` 都会落到 `loki`)。
String localSeriesKey(String title) =>
    title.toLowerCase().replaceAll(_seriesKeyNoise, '');

/// 剧名归一化时抹掉的字符:空白 + 常见分隔/包装符号(半角与全角都收)。
final RegExp _seriesKeyNoise = RegExp(
  r'''[\s._\-–—·・~～@#$%&*+=|\\/?!,;:'"“”‘’《》〈〉「」【】〔〕\[\](){}（）]+''',
);

/// 一批待入库条目分出来的一份「库」。
class LocalLibraryGroup {
  const LocalLibraryGroup({
    required this.key,
    required this.name,
    required this.items,
  });

  /// 归并键:同键的条目属于同一个库。
  ///
  /// - 带季/集号的(剧集):`series:<归一化剧名>`;
  /// - 没有季集号的(散装电影/录音):`dir:<所在目录>`。
  final String key;

  /// 建议的库名(剧名,或目录名/条目名);可能为空,由调用方兜底。
  final String name;

  final List<LocalMediaItem> items;

  @override
  String toString() => 'LocalLibraryGroup($key, $name, ${items.length} items)';
}

/// 把一批条目分成几份「库」(规格 §8.1:一次挑两部剧就该两张卡)。
///
/// 规则:
/// - 带季号或集号的条目按**归一化剧名**归堆 —— 这是「一部剧加两集变两张卡」
///   那个问题的正面解法;
/// - 没有季集号的条目按**所在目录**归堆,保持「一个目录一个库」的老观感,
///   重复从同一个目录挑电影也不会每次开一张新卡;
/// - 分组顺序 = 每组第一条在入参里的顺序,结果稳定可测。
List<LocalLibraryGroup> groupLocalItemsForLibraries(
  List<LocalMediaItem> items,
) {
  // Dart 的 Map 保持插入顺序,所以这一趟下来组序就是「每组第一条的先后」。
  final buckets = <String, List<LocalMediaItem>>{};
  final seriesGroup = <String, bool>{};
  for (final item in items) {
    final isSeries = item.season != null || item.episode != null;
    final String key;
    if (isSeries) {
      final normalized = localSeriesKey(item.title);
      key = normalized.isEmpty ? 'series-title:${item.title}' : 'series:$normalized';
    } else {
      key = 'dir:${localParentKey(item.location)}';
    }
    (buckets[key] ??= <LocalMediaItem>[]).add(item);
    seriesGroup[key] = isSeries;
  }

  return [
    for (final entry in buckets.entries)
      LocalLibraryGroup(
        key: entry.key,
        name: (seriesGroup[entry.key] ?? false)
            ? _dominantTitle(entry.value)
            : _looseGroupName(entry.value),
        items: List.unmodifiable(entry.value),
      ),
  ];
}

/// 一组里出现次数最多的标题(并列取先出现的那个)。
String _dominantTitle(List<LocalMediaItem> items) {
  final counts = <String, int>{};
  for (final item in items) {
    final title = item.title.trim();
    if (title.isEmpty) continue;
    counts[title] = (counts[title] ?? 0) + 1;
  }
  var best = '';
  var bestCount = 0;
  for (final entry in counts.entries) {
    if (entry.value > bestCount) {
      best = entry.key;
      bestCount = entry.value;
    }
  }
  return best;
}

/// 散装组的名字:**目录名**(`Movies` / `Download` 之类)。
///
/// 刻意不用组里某一条的标题:同一个目录里第一张卡叫「Inception」,第二部电影并
/// 进来之后这个名字就在骗人了。目录拿不到(奇怪的 uri)才退回标题。
String _looseGroupName(List<LocalMediaItem> items) {
  final directory = localParentDisplayName(items.first.location);
  if (directory.isNotEmpty) return directory;
  return _dominantTitle(items);
}
