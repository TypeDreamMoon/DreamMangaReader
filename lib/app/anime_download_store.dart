import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:hls/hls.dart';
import 'package:path_provider/path_provider.dart';

import '../core/downloads/content_download_task.dart';
import '../core/downloads/download_executor.dart';
import '../core/downloads/download_task.dart';
import '../core/source/models.dart';
import '../core/source/source_registry.dart';
import '../features/anime/playback/hls_cache_gateway.dart';

typedef AnimeDownloadRootProvider = Future<String> Function();
typedef AnimeTrackProvider = Future<List<VideoTrack>> Function(
  String sourceId,
  String animeId,
  String episodeId,
);

class DownloadedAnimeEpisode {
  const DownloadedAnimeEpisode({
    required this.sourceId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeId,
    required this.episodeTitle,
    required this.directory,
    required this.resourceCount,
    required this.byteCount,
    required this.completedAt,
  });

  final String sourceId;
  final String animeId;
  final String animeTitle;
  final String episodeId;
  final String episodeTitle;
  final String directory;
  final int resourceCount;
  final int byteCount;
  final int completedAt;

  String get key => _episodeKey(sourceId, animeId, episodeId);
  String get manifestPath => '$directory${Platform.pathSeparator}index.m3u8';

  Map<String, Object?> toJson(String relativeDirectory) => {
        'sourceId': sourceId,
        'animeId': animeId,
        'animeTitle': animeTitle,
        'episodeId': episodeId,
        'episodeTitle': episodeTitle,
        'directory': relativeDirectory,
        'resourceCount': resourceCount,
        'byteCount': byteCount,
        'completedAt': completedAt,
      };
}

class AnimeDownloadStore extends ChangeNotifier implements DownloadExecutor {
  AnimeDownloadStore({
    AnimeDownloadRootProvider? rootProvider,
    AnimeTrackProvider? trackProvider,
    HlsUpstreamClient? upstream,
  })  : _rootProvider = rootProvider ?? _applicationSupportRoot,
        _trackProvider = trackProvider ?? _defaultTrackProvider,
        _upstream = upstream ?? DioHlsUpstreamClient(Dio());

  final AnimeDownloadRootProvider _rootProvider;
  final AnimeTrackProvider _trackProvider;
  final HlsUpstreamClient _upstream;
  final Map<String, DownloadedAnimeEpisode> _completed = {};
  Directory? _root;
  bool _disposed = false;

  @override
  DownloadContentKind get kind => DownloadContentKind.anime;

  List<DownloadedAnimeEpisode> get downloads {
    final values = _completed.values.toList()
      ..sort((left, right) => right.completedAt.compareTo(left.completedAt));
    return List.unmodifiable(values);
  }

  bool isDownloaded(String sourceId, String animeId, String episodeId) =>
      _completed.containsKey(_episodeKey(sourceId, animeId, episodeId));

  String? localManifest(String sourceId, String animeId, String episodeId) =>
      _completed[_episodeKey(sourceId, animeId, episodeId)]?.manifestPath;

  Future<void> load() async {
    final root = Directory(await _rootProvider());
    await root.create(recursive: true);
    if (_disposed) return;
    _root = root;
    _completed.clear();
    final index = await _recoverIndex(root);
    if (index != null) {
      try {
        final decoded = jsonDecode(await index.readAsString(encoding: utf8));
        if (decoded is List) {
          for (final value in decoded.whereType<Map>()) {
            final json = value.cast<String, dynamic>();
            final relative = json['directory'];
            if (relative is! String || !_safeDirectoryName(relative)) continue;
            final directory = Directory(
              '${root.path}${Platform.pathSeparator}$relative',
            );
            final record = DownloadedAnimeEpisode(
              sourceId: json['sourceId'] as String,
              animeId: json['animeId'] as String,
              animeTitle: json['animeTitle'] as String,
              episodeId: json['episodeId'] as String,
              episodeTitle: json['episodeTitle'] as String,
              directory: directory.path,
              resourceCount: (json['resourceCount'] as num).toInt(),
              byteCount: (json['byteCount'] as num).toInt(),
              completedAt: (json['completedAt'] as num).toInt(),
            );
            if (await File(record.manifestPath).exists()) {
              _completed[record.key] = record;
            }
          }
        }
      } catch (_) {
        _completed.clear();
      }
    }
    _notify();
  }

  @override
  Future<void> execute(
    DownloadExecutionContext context,
    DownloadTask task,
  ) async {
    final root = _root;
    if (root == null) throw StateError('AnimeDownloadStore is not loaded');
    final request = ContentDownloadRequest.fromTask(task);
    final key = _episodeKey(
      request.sourceId,
      request.contentId,
      request.chapterId,
    );
    if (_completed.containsKey(key)) return;
    context.cancellation.throwIfCancelled();
    final tracks = await _trackProvider(
      request.sourceId,
      request.contentId,
      request.chapterId,
    );
    context.cancellation.throwIfCancelled();
    final track = _selectTrack(tracks);
    final relativeDirectory = _directoryName(
      request.sourceId,
      request.contentId,
      request.chapterId,
    );
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}$relativeDirectory',
    );
    final result = await AnimeHlsPackageWriter(_upstream).write(
      playlistUri: Uri.parse(track.url),
      headers: Map.unmodifiable(track.headers ?? const {}),
      directory: directory,
      context: context,
    );
    context.cancellation.throwIfCancelled();
    final record = DownloadedAnimeEpisode(
      sourceId: request.sourceId,
      animeId: request.contentId,
      animeTitle: task.title,
      episodeId: request.chapterId,
      episodeTitle: task.itemTitle,
      directory: directory.path,
      resourceCount: result.resourceCount,
      byteCount: result.byteCount,
      completedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _completed[key] = record;
    try {
      await _persist();
    } catch (_) {
      _completed.remove(key);
      rethrow;
    }
    _notify();
  }

  VideoTrack _selectTrack(List<VideoTrack> tracks) {
    final candidates = tracks.where((track) => track.hls).toList();
    if (candidates.isEmpty) {
      throw const UnsupportedAnimePlaylist('该分集没有可下载的 HLS 轨道');
    }
    candidates.sort(
        (left, right) => _qualityHeight(left).compareTo(_qualityHeight(right)));
    final eligible = candidates.where((track) => _qualityHeight(track) <= 1080);
    return eligible.isNotEmpty ? eligible.last : candidates.first;
  }

  int _qualityHeight(VideoTrack track) {
    final match = RegExp(r'(\d{3,4})').firstMatch(track.quality);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  Future<File?> _recoverIndex(Directory root) async {
    final index = File('${root.path}${Platform.pathSeparator}index.json');
    if (await index.exists()) return index;
    final backup = File('${index.path}.backup');
    if (await backup.exists()) {
      await backup.rename(index.path);
      return index;
    }
    return null;
  }

  Future<void> _persist() async {
    final root = _root!;
    final index = File('${root.path}${Platform.pathSeparator}index.json');
    final temporary = File('${index.path}.download');
    final backup = File('${index.path}.backup');
    final values = _completed.values.map((record) {
      return record.toJson(_directoryName(
        record.sourceId,
        record.animeId,
        record.episodeId,
      ));
    }).toList();
    await temporary.writeAsString(
      jsonEncode(values),
      encoding: utf8,
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await index.exists()) await index.rename(backup.path);
    try {
      await temporary.rename(index.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await index.exists() && await backup.exists()) {
        await backup.rename(index.path);
      }
      rethrow;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class AnimeDownloadScope extends InheritedNotifier<AnimeDownloadStore> {
  const AnimeDownloadScope({
    super.key,
    required AnimeDownloadStore store,
    required super.child,
  }) : super(notifier: store);

  static AnimeDownloadStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AnimeDownloadScope>();
    assert(scope != null, 'AnimeDownloadScope not found in context');
    return scope!.notifier!;
  }

  static AnimeDownloadStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AnimeDownloadScope>();
    assert(scope != null, 'AnimeDownloadScope not found in context');
    return scope!.notifier!;
  }

  static AnimeDownloadStore? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AnimeDownloadScope>()?.notifier;
}

class UnsupportedAnimePlaylist implements Exception {
  const UnsupportedAnimePlaylist(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一集里挑好的那条视频清单,外加(如果有的话)跟着它走的独立音轨。
class _ResolvedPlaylist {
  const _ResolvedPlaylist({
    required this.video,
    this.variant,
    this.audio,
    this.audioRendition,
  });

  final HlsMediaPlaylist video;
  final HlsVariant? variant;
  final HlsMediaPlaylist? audio;
  final HlsRendition? audioRendition;
}

class AnimeHlsPackageResult {
  const AnimeHlsPackageResult({
    required this.manifest,
    required this.resourceCount,
    required this.byteCount,
  });

  final File manifest;
  final int resourceCount;
  final int byteCount;
}

class AnimeHlsPackageWriter {
  const AnimeHlsPackageWriter(this.upstream);

  final HlsUpstreamClient upstream;

  Future<AnimeHlsPackageResult> write({
    required Uri playlistUri,
    required Map<String, String> headers,
    required Directory directory,
    required DownloadExecutionContext context,
  }) async {
    context.cancellation.throwIfCancelled();
    await directory.create(recursive: true);
    final manifest =
        File('${directory.path}${Platform.pathSeparator}index.m3u8');
    if (await manifest.exists()) await manifest.delete();

    // 凭据只认原始清单的主机。变体/分片/密钥的 URI 都由上游清单决定,
    // 跨主机时必须脱掉认证头(与播放网关同一条规则)。
    final originHost = playlistUri.host;
    final resolved = await _resolveMediaPlaylist(
      playlistUri,
      headers,
      originHost,
    );
    final playlist = resolved.video;
    _requirePlayable(playlist);
    final audio = resolved.audio;
    if (audio != null) _requirePlayable(audio);

    final total =
        _resourceCount(playlist) + (audio == null ? 0 : _resourceCount(audio));
    var completed = 0;
    var byteCount = 0;

    Future<void> downloaded(File file) async {
      completed++;
      byteCount += await file.length();
      await context.reportProgress(completed, total);
      await context.checkpoint();
    }

    final localVideo = await _downloadPlaylist(
      playlist: playlist,
      prefix: '',
      headers: headers,
      originHost: originHost,
      directory: directory,
      context: context,
      downloaded: downloaded,
    );
    final localAudio = audio == null
        ? null
        : await _downloadPlaylist(
            playlist: audio,
            prefix: 'audio-',
            headers: headers,
            originHost: originHost,
            directory: directory,
            context: context,
            downloaded: downloaded,
          );

    if (localAudio == null) {
      await _writePlaylist(manifest, localVideo, context);
    } else {
      // 音轨是主清单里独立的 EXT-X-MEDIA 渲染流,不在视频分片里 —— 只存视频清单
      // 的话离线播放就是一部默片。落盘成「主清单 + 视频清单 + 音频清单」三件套。
      final base = directory.path + Platform.pathSeparator;
      await _writePlaylist(File('${base}video.m3u8'), localVideo, context);
      await _writePlaylist(File('${base}audio.m3u8'), localAudio, context);
      await _writePlaylist(
        manifest,
        _localMaster(resolved),
        context,
      );
    }
    return AnimeHlsPackageResult(
      manifest: manifest,
      resourceCount: total,
      byteCount: byteCount,
    );
  }

  void _requirePlayable(HlsMediaPlaylist playlist) {
    if (playlist.isLive) {
      throw const UnsupportedAnimePlaylist('暂不支持下载直播 HLS 清单');
    }
    if (playlist.segments.isEmpty) {
      throw const UnsupportedAnimePlaylist('HLS 清单没有可下载分片');
    }
  }

  /// 这一条清单一共有多少个要下的资源(分片 + 初始化段 + 去重后的密钥)。
  int _resourceCount(HlsMediaPlaylist playlist) {
    final keys = <String>{};
    for (final segment in playlist.segments) {
      final key = segment.key;
      if (key == null || key.method == 'NONE' || key.uri == null) continue;
      keys.add(key.uri.toString());
    }
    return playlist.segments.length +
        (playlist.initSegment == null ? 0 : 1) +
        keys.length;
  }

  /// 指向包内三个本地清单的主清单。分辨率/带宽沿用选中的那条变体,音轨挂在
  /// 一个固定的 GROUP-ID 上 —— 包里本来也只有一路音频。
  HlsMasterPlaylist _localMaster(_ResolvedPlaylist resolved) {
    const audioGroup = 'audio';
    final rendition = resolved.audioRendition!;
    final variant = resolved.variant;
    return HlsMasterPlaylist(
      version: resolved.video.version,
      independentSegments: resolved.video.independentSegments,
      renditions: [
        HlsRendition(
          type: HlsMediaType.audio,
          groupId: audioGroup,
          name: rendition.name,
          language: rendition.language,
          channels: rendition.channels,
          isDefault: true,
          autoselect: true,
          uri: Uri(path: 'audio.m3u8'),
        ),
      ],
      variants: [
        HlsVariant(
          uri: Uri(path: 'video.m3u8'),
          bandwidth: variant?.bandwidth ?? 1,
          codecs: variant?.codecs,
          width: variant?.width,
          height: variant?.height,
          frameRate: variant?.frameRate,
          audioGroupId: audioGroup,
        ),
      ],
    );
  }

  Future<void> _writePlaylist(
    File target,
    HlsPlaylist playlist,
    DownloadExecutionContext context,
  ) async {
    final temporary = File('${target.path}.download');
    await temporary.writeAsString(
      HlsComposer.compose(playlist),
      encoding: utf8,
      flush: true,
    );
    context.cancellation.throwIfCancelled();
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  /// 把一条媒体清单连同它的密钥/初始化段/分片全部落到 [directory],返回改写成
  /// 本地文件名的清单。[prefix] 把视频和音频的分片分开命名。
  Future<HlsMediaPlaylist> _downloadPlaylist({
    required HlsMediaPlaylist playlist,
    required String prefix,
    required Map<String, String> headers,
    required String originHost,
    required Directory directory,
    required DownloadExecutionContext context,
    required Future<void> Function(File file) downloaded,
  }) async {
    final uniqueKeys = <String, HlsSegmentKey>{};
    for (final segment in playlist.segments) {
      final key = segment.key;
      if (key == null || key.method == 'NONE') continue;
      if (key.method != 'AES-128' ||
          (key.keyFormat != null && key.keyFormat != 'identity') ||
          key.uri == null) {
        throw const UnsupportedAnimePlaylist('仅支持无 DRM 的 AES-128 HLS 加密');
      }
      uniqueKeys.putIfAbsent(key.uri.toString(), () => key);
    }

    final localKeys = <String, HlsSegmentKey>{};
    var keyIndex = 0;
    for (final entry in uniqueKeys.entries) {
      context.cancellation.throwIfCancelled();
      final name = '${prefix}key-${keyIndex++}.bin';
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      await _downloadResource(
        uri: entry.value.uri!,
        headers: headers,
        originHost: originHost,
        output: file,
        context: context,
      );
      if (await file.length() != 16) {
        throw const UnsupportedAnimePlaylist('AES-128 密钥长度必须为 16 字节');
      }
      localKeys[entry.key] = HlsSegmentKey(
        method: entry.value.method,
        uri: Uri(path: name),
        iv: entry.value.iv,
        keyFormat: entry.value.keyFormat,
        keyFormatVersions: entry.value.keyFormatVersions,
      );
      await downloaded(file);
    }

    HlsInitSegment? localInit;
    final nextOffsets = <String, int>{};
    final sourceInit = playlist.initSegment;
    if (sourceInit != null) {
      context.cancellation.throwIfCancelled();
      final name = '${prefix}init-0.bin';
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      final range = sourceInit.byteRange;
      final start = range == null
          ? null
          : range.offset ?? nextOffsets[sourceInit.uri.toString()] ?? 0;
      await _downloadResource(
        uri: sourceInit.uri,
        headers: headers,
        originHost: originHost,
        output: file,
        context: context,
        rangeStart: start,
        rangeLength: range?.length,
      );
      if (range != null) {
        nextOffsets[sourceInit.uri.toString()] = start! + range.length;
      }
      localInit = HlsInitSegment(uri: Uri(path: name));
      await downloaded(file);
    }

    final localSegments = <HlsMediaSegment>[];
    for (var index = 0; index < playlist.segments.length; index++) {
      context.cancellation.throwIfCancelled();
      final source = playlist.segments[index];
      final name = '${prefix}segment-$index.bin';
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      final range = source.byteRange;
      final start = range == null
          ? null
          : range.offset ?? nextOffsets[source.uri.toString()] ?? 0;
      await _downloadResource(
        uri: source.uri,
        headers: headers,
        originHost: originHost,
        output: file,
        context: context,
        rangeStart: start,
        rangeLength: range?.length,
      );
      if (range != null) {
        nextOffsets[source.uri.toString()] = start! + range.length;
      }
      final sourceKey = source.key;
      localSegments.add(HlsMediaSegment(
        uri: Uri(path: name),
        duration: source.duration,
        title: source.title,
        key: sourceKey == null || sourceKey.method == 'NONE'
            ? sourceKey
            : localKeys[sourceKey.uri.toString()],
        programDateTime: source.programDateTime,
        discontinuity: source.discontinuity,
      ));
      await downloaded(file);
    }

    return HlsMediaPlaylist(
      version: playlist.version,
      targetDuration: playlist.targetDuration,
      mediaSequence: playlist.mediaSequence,
      discontinuitySequence: playlist.discontinuitySequence,
      startOffset: playlist.startOffset,
      initSegment: localInit,
      hasEndTag: true,
      playlistType: 'VOD',
      independentSegments: playlist.independentSegments,
      segments: localSegments,
    );
  }

  Future<_ResolvedPlaylist> _resolveMediaPlaylist(
    Uri uri,
    Map<String, String> headers,
    String originHost,
  ) async {
    final root = await _fetchPlaylist(uri, headers, originHost);
    if (root is HlsMediaPlaylist) {
      return _ResolvedPlaylist(video: root);
    }
    if (root is! HlsMasterPlaylist || root.variants.isEmpty) {
      throw const UnsupportedAnimePlaylist('未知或空的 HLS 清单');
    }
    final variants = root.variants.toList()
      ..sort((left, right) {
        final leftHeight = left.height ?? 0;
        final rightHeight = right.height ?? 0;
        return leftHeight != rightHeight
            ? leftHeight.compareTo(rightHeight)
            : left.bandwidth.compareTo(right.bandwidth);
      });
    final eligible = variants.where((variant) => (variant.height ?? 0) <= 1080);
    final selected = eligible.isNotEmpty ? eligible.last : variants.first;
    final selectedUri = selected.uri;
    final media = await _fetchPlaylist(selectedUri, headers, originHost);
    if (media is! HlsMediaPlaylist) {
      throw const UnsupportedAnimePlaylist('HLS 变体不是媒体清单');
    }
    // 音轨常常是独立的 EXT-X-MEDIA 渲染流(变体里只有画面)。跟着选中变体的
    // AUDIO 组走;没有 URI 的那种是混流音轨,已经在视频分片里了,不用另存。
    final rendition = _audioRenditionFor(root, selected);
    if (rendition == null) {
      return _ResolvedPlaylist(video: media, variant: selected);
    }
    final audio = await _fetchPlaylist(rendition.uri!, headers, originHost);
    if (audio is! HlsMediaPlaylist) {
      throw const UnsupportedAnimePlaylist('HLS 音轨不是媒体清单');
    }
    return _ResolvedPlaylist(
      video: media,
      variant: selected,
      audio: audio,
      audioRendition: rendition,
    );
  }

  HlsRendition? _audioRenditionFor(
    HlsMasterPlaylist master,
    HlsVariant variant,
  ) {
    final group = variant.audioGroupId;
    if (group == null || group.isEmpty) return null;
    final candidates = master.renditions
        .where((rendition) =>
            rendition.type == HlsMediaType.audio &&
            rendition.groupId == group &&
            rendition.uri != null)
        .toList();
    if (candidates.isEmpty) return null;
    return candidates.firstWhere(
      (rendition) => rendition.isDefault,
      orElse: () => candidates.first,
    );
  }

  Future<HlsPlaylist> _fetchPlaylist(
    Uri uri,
    Map<String, String> headers,
    String originHost,
  ) async {
    final response = await upstream.get(
      uri,
      headers: scopeHlsCredentialHeaders(
        headers,
        originHost: originHost,
        target: uri,
      ),
    );
    _requireSuccess(uri, response);
    final parsed = HlsParser.parse(
      utf8.decode(response.bytes),
      baseUri: uri.resolve('.'),
    );
    return HlsComposer.normalize(parsed);
  }

  Future<void> _downloadResource({
    required Uri uri,
    required Map<String, String> headers,
    required String originHost,
    required File output,
    required DownloadExecutionContext context,
    int? rangeStart,
    int? rangeLength,
  }) async {
    if (await output.exists() && await output.length() > 0) return;
    context.cancellation.throwIfCancelled();
    final response = await upstream.get(
      uri,
      headers: scopeHlsCredentialHeaders(
        headers,
        originHost: originHost,
        target: uri,
      ),
      rangeStart: rangeStart,
      rangeLength: rangeLength,
    );
    _requireSuccess(uri, response);
    if (response.bytes.isEmpty) {
      throw StateError('HLS 资源为空: $uri');
    }
    final temporary = File('${output.path}.download');
    await temporary.writeAsBytes(response.bytes, flush: true);
    context.cancellation.throwIfCancelled();
    if (await output.exists()) await output.delete();
    await temporary.rename(output.path);
  }

  void _requireSuccess(Uri uri, HlsUpstreamResponse response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HLS 请求失败: ${response.statusCode}', uri: uri);
    }
  }
}

Future<String> _applicationSupportRoot() async {
  final support = await getApplicationSupportDirectory();
  return '${support.path}${Platform.pathSeparator}anime-downloads';
}

Future<List<VideoTrack>> _defaultTrackProvider(
  String sourceId,
  String animeId,
  String episodeId,
) async {
  final meta =
      registeredSources.where((source) => source.id == sourceId).firstOrNull;
  if (meta == null || !meta.isAnime) {
    throw StateError('anime source is unavailable: $sourceId');
  }
  final source = buildSource(meta);
  try {
    return await source.getVideo(animeId, episodeId);
  } finally {
    source.dispose();
  }
}

String _episodeKey(String sourceId, String animeId, String episodeId) =>
    jsonEncode([sourceId, animeId, episodeId]);

String _directoryName(String sourceId, String animeId, String episodeId) =>
    base64Url
        .encode(utf8.encode(_episodeKey(sourceId, animeId, episodeId)))
        .replaceAll('=', '');

bool _safeDirectoryName(String value) =>
    value.isNotEmpty && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
