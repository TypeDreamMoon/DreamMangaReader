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
    this.addedAt = 0,
    this.lastPlayedAt,
  });

  /// uuid,只作内部键与进度的 `episodeId`;跨设备/跨次启动不变。
  final String id;
  final String libraryId;

  /// 清理后的展示标题(去扩展名、去分辨率等噪声),由文件名解析器给出。
  final String title;

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

int? _intField(Map<Object?, Object?> json, String key) =>
    (json[key] as num?)?.toInt();

/// 字幕数组:非列表按空处理,列表里的非 Map 元素跳过(与旧行为一致)。
List<LocalSubtitle> _subtitlesFromJson(Object? value) => [
      for (final entry in (value as List?) ?? const [])
        if (entry is Map) LocalSubtitle.fromJson(entry),
    ];
