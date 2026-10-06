import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:hls/hls.dart';
import 'package:path_provider/path_provider.dart';

import '../core/downloads/content_download_task.dart';
import '../core/downloads/download_coordinator.dart';
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

/// 离线包的入口文件名。HLS 包是改写过的清单;直链包是下下来的那个文件。
const _hlsManifestName = 'index.m3u8';

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
    this.mediaName = _hlsManifestName,
    this.audioName,
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

  /// 包目录里的入口文件名(HLS 是 `index.m3u8`,直链是 `video.mp4` 之类)。
  final String mediaName;

  /// DASH 那种音视频分离的源,音轨单独一个文件;null = 视频自带声音。
  final String? audioName;

  String get key => _episodeKey(sourceId, animeId, episodeId);
  String get mediaPath => '$directory${Platform.pathSeparator}$mediaName';
  String? get audioPath => audioName == null
      ? null
      : '$directory${Platform.pathSeparator}$audioName';

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
        'media': mediaName,
        if (audioName != null) 'audio': audioName,
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
  final Set<String> _undownloadable = {};
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

  /// 这一集的离线包(没下过 = null)。离线播放据此拼本地地址。
  DownloadedAnimeEpisode? recordFor(
    String sourceId,
    String animeId,
    String episodeId,
  ) =>
      _completed[_episodeKey(sourceId, animeId, episodeId)];

  /// 这一集能不能下。
  ///
  /// 源给了什么轨道要联网才知道,所以默认都当作能下;真的问出来「一条都下不了」
  /// 之后记在这里,界面据此把下载按钮置灰,而不是让人一次次点出同一条报错。
  bool isDownloadable(String sourceId, String animeId, String episodeId) =>
      !_undownloadable.contains(_episodeKey(sourceId, animeId, episodeId));

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
              mediaName: _safeFileName(json['media']) ?? _hlsManifestName,
              audioName: _safeFileName(json['audio']),
            );
            if (await File(record.mediaPath).exists()) {
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

  /// 删掉一集的离线包:先撤下载任务,再抹掉磁盘上的分片和包目录。
  ///
  /// 目录名是从 (源, 番剧, 分集) 算出来的,不查索引 —— 取消或失败的任务从没进过
  /// [_completed],但它留下的半个包目录一样占着几百兆。协调器的 `remove()` 只删
  /// 任务记录、不回调执行器,所以这一步必须由这里补上,否则那些 `segment-*.bin`
  /// 会永远躺在应用目录里。
  ///
  /// 先撤任务再删文件:反过来的话,正在跑的那条会立刻把刚删掉的分片重新写回来。
  Future<void> delete(
    String sourceId,
    String animeId,
    String episodeId, {
    DownloadCoordinator? coordinator,
  }) async {
    await coordinator?.remove(contentDownloadTaskId(
      DownloadContentKind.anime,
      sourceId,
      animeId,
      episodeId,
    ));
    final root = _root;
    if (root != null) {
      final directory = Directory(
        '${root.path}${Platform.pathSeparator}'
        '${_directoryName(sourceId, animeId, episodeId)}',
      );
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } catch (_) {
        // 文件被播放器占着(Windows 上很常见):索引里已经没有这一集了,
        // 目录留给下一次删除 —— 总好过整条路径抛出去,让按钮看起来没反应。
      }
    }
    if (_completed.remove(_episodeKey(sourceId, animeId, episodeId)) != null) {
      try {
        await _persist();
      } catch (_) {
        // 索引写不回去也无所谓:文件已经不在了,下次 load() 会因为缺清单剔掉它。
      }
    }
    _notify();
  }

  /// 删掉整部番剧已下载的分集(书架侧「删除整部」)。
  Future<void> deleteSeries(
    String sourceId,
    String animeId, {
    DownloadCoordinator? coordinator,
  }) async {
    final episodes = [
      for (final record in _completed.values)
        if (record.sourceId == sourceId && record.animeId == animeId)
          record.episodeId,
    ];
    for (final episodeId in episodes) {
      await delete(sourceId, animeId, episodeId, coordinator: coordinator);
    }
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
    final VideoTrack track;
    try {
      track = _selectTrack(tracks);
    } on UnsupportedAnimePlaylist {
      // 记下来,界面把这一集的下载按钮置灰 —— 再点也只会得到同一条报错。
      _undownloadable.add(key);
      _notify();
      rethrow;
    }
    _undownloadable.remove(key);
    final relativeDirectory = _directoryName(
      request.sourceId,
      request.contentId,
      request.chapterId,
    );
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}$relativeDirectory',
    );
    final headers = Map<String, String>.unmodifiable(
      track.headers ?? const <String, String>{},
    );
    final String mediaName;
    final String? audioName;
    final int resourceCount;
    final int byteCount;
    if (track.hls) {
      final result = await AnimeHlsPackageWriter(_upstream).write(
        playlistUri: Uri.parse(track.url),
        headers: headers,
        directory: directory,
        context: context,
      );
      mediaName = _hlsManifestName;
      audioName = null;
      resourceCount = result.resourceCount;
      byteCount = result.byteCount;
    } else {
      final result = await AnimeFilePackageWriter(_upstream).write(
        track: track,
        headers: headers,
        directory: directory,
        context: context,
      );
      mediaName = result.mediaName;
      audioName = result.audioName;
      resourceCount = result.resourceCount;
      byteCount = result.byteCount;
    }
    context.cancellation.throwIfCancelled();
    final record = DownloadedAnimeEpisode(
      sourceId: request.sourceId,
      animeId: request.contentId,
      animeTitle: task.title,
      episodeId: request.chapterId,
      episodeTitle: task.itemTitle,
      directory: directory.path,
      resourceCount: resourceCount,
      byteCount: byteCount,
      completedAt: DateTime.now().millisecondsSinceEpoch,
      mediaName: mediaName,
      audioName: audioName,
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

  /// 挑一条下得动的轨道。
  ///
  /// HLS 优先 —— 分片包能一段一段续、清单能改写成本地相对路径。但番剧源里只有一半
  /// 给 HLS:B站给的是 DASH 分离流和老式 durl 整段 mp4/flv,全都 `hls: false`,
  /// 于是「没有可下载的 HLS 轨道」把每一次点击都挡了回去。直链现在照样收:整段文件
  /// 按 Range 分块拉下来,DASH 的音轨作为第二个文件一起存,离线播放交给播放器合流
  /// (在线播放本来就是这么放的,不需要在这里转封装)。
  VideoTrack _selectTrack(List<VideoTrack> tracks) {
    final remote = tracks.where((track) => _isRemote(track.url));
    final hls = _preferredTrack(remote.where((track) => track.hls));
    if (hls != null) return hls;
    final direct = _preferredTrack(remote.where((track) => !track.hls));
    if (direct != null) return direct;
    throw const UnsupportedAnimePlaylist('该分集没有可下载的视频轨道');
  }

  /// 同一集里挑清晰度:不超过 1080 的最高一档,全都超了就取最低的那档。
  VideoTrack? _preferredTrack(Iterable<VideoTrack> tracks) {
    final candidates = tracks.toList()
      ..sort((left, right) =>
          _qualityHeight(left).compareTo(_qualityHeight(right)));
    if (candidates.isEmpty) return null;
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

class AnimeFilePackageResult {
  const AnimeFilePackageResult({
    required this.mediaName,
    required this.audioName,
    required this.resourceCount,
    required this.byteCount,
  });

  final String mediaName;
  final String? audioName;
  final int resourceCount;
  final int byteCount;
}

/// 直链轨道(durl 的 mp4/flv、DASH 的 m4s)的离线包。
///
/// 上游客户端一次只回一整段字节,整集几百兆全塞进内存显然不行,所以按块要 Range
/// 追加写进 `.part`。断点续传是顺带的:重来一次直接从 `.part` 现有长度接着要。
/// 服务器不认 Range(回 200 而不是 206)时退化成整段重下,不会把两段拼成坏文件。
class AnimeFilePackageWriter {
  const AnimeFilePackageWriter(
    this.upstream, {
    this.chunkSize = 4 * 1024 * 1024,
  });

  final HlsUpstreamClient upstream;
  final int chunkSize;

  Future<AnimeFilePackageResult> write({
    required VideoTrack track,
    required Map<String, String> headers,
    required Directory directory,
    required DownloadExecutionContext context,
  }) async {
    context.cancellation.throwIfCancelled();
    await directory.create(recursive: true);
    final videoUri = Uri.parse(track.url);
    final originHost = videoUri.host;
    final audioUrl = track.audioUrl;
    final audioUri = audioUrl == null || audioUrl.isEmpty
        ? null
        : Uri.tryParse(audioUrl);

    var byteCount = 0;
    var expected = 0;
    Future<void> progress(int written, int? total) async {
      await context.reportProgress(
        byteCount + written,
        expected > 0 ? expected : byteCount + written,
      );
      await context.checkpoint();
    }

    final mediaName = 'video.${_extensionOf(videoUri, 'mp4')}';
    byteCount += await _downloadFile(
      uri: videoUri,
      headers: headers,
      originHost: originHost,
      output: File('${directory.path}${Platform.pathSeparator}$mediaName'),
      context: context,
      onProgress: progress,
      onTotalKnown: (total) => expected += total,
    );

    String? audioName;
    if (audioUri != null && audioUri.hasScheme) {
      audioName = 'audio.${_extensionOf(audioUri, 'm4a')}';
      byteCount += await _downloadFile(
        uri: audioUri,
        headers: headers,
        originHost: originHost,
        output: File('${directory.path}${Platform.pathSeparator}$audioName'),
        context: context,
        onProgress: progress,
        onTotalKnown: (total) => expected += total,
      );
    }

    context.cancellation.throwIfCancelled();
    await context.reportProgress(byteCount, byteCount);
    return AnimeFilePackageResult(
      mediaName: mediaName,
      audioName: audioName,
      resourceCount: audioName == null ? 1 : 2,
      byteCount: byteCount,
    );
  }

  Future<int> _downloadFile({
    required Uri uri,
    required Map<String, String> headers,
    required String originHost,
    required File output,
    required DownloadExecutionContext context,
    required Future<void> Function(int written, int? total) onProgress,
    required void Function(int total) onTotalKnown,
  }) async {
    if (await output.exists()) {
      final length = await output.length();
      if (length > 0) {
        onTotalKnown(length);
        return length;
      }
    }
    final part = File('${output.path}.part');
    var written = await part.exists() ? await part.length() : 0;
    int? total;
    var reported = false;
    while (total == null || written < total) {
      context.cancellation.throwIfCancelled();
      final response = await upstream.get(
        uri,
        headers: scopeHlsCredentialHeaders(
          headers,
          originHost: originHost,
          target: uri,
        ),
        rangeStart: written,
        rangeLength: chunkSize,
      );
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        // 已经拿完了(续传时最常见)。
        break;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('直链请求失败: ${response.statusCode}', uri: uri);
      }
      final bytes = response.bytes;
      if (response.statusCode != HttpStatus.partialContent) {
        // 服务器无视了 Range,回的是整段:从头覆盖,别把两段拼成坏文件。
        if (bytes.isEmpty) throw StateError('直链响应为空: $uri');
        await part.writeAsBytes(bytes, flush: true);
        written = bytes.length;
        total = written;
      } else {
        if (bytes.isEmpty) break;
        await part.writeAsBytes(bytes, mode: FileMode.append, flush: true);
        written += bytes.length;
        total ??= _contentRangeTotal(response.headers);
        if (total == null && bytes.length < chunkSize) total = written;
      }
      if (!reported && total != null) {
        reported = true;
        onTotalKnown(total);
      }
      await onProgress(written, total);
    }
    if (written <= 0) throw StateError('直链响应为空: $uri');
    if (!reported) onTotalKnown(written);
    context.cancellation.throwIfCancelled();
    if (await output.exists()) await output.delete();
    await part.rename(output.path);
    return written;
  }
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

/// 索引里的文件名只认包目录内的普通名字 —— 存档被改花了也不能指到目录外面去。
String? _safeFileName(Object? value) {
  if (value is! String) return null;
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(value)) return null;
  return value.contains('..') ? null : value;
}

/// 只下 http(s) 直链;源偶尔会给空串或 `blob:`/`data:` 之类,这些下不了。
bool _isRemote(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// 从 URL 末段猜扩展名(`…/1080.m4s?token=…` → `m4s`),猜不出用兜底值。
String _extensionOf(Uri uri, String fallback) {
  final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final dot = last.lastIndexOf('.');
  if (dot <= 0 || dot == last.length - 1) return fallback;
  final extension = last.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(extension) ? extension : fallback;
}

/// `Content-Range: bytes 0-4194303/12345678` → 12345678(`*` 或缺失 = null)。
int? _contentRangeTotal(Map<String, List<String>> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() != HttpHeaders.contentRangeHeader) continue;
    final value = entry.value.firstOrNull;
    if (value == null) return null;
    final match = RegExp(r'/\s*(\d+)\s*$').firstMatch(value);
    return match == null ? null : int.tryParse(match.group(1)!);
  }
  return null;
}
