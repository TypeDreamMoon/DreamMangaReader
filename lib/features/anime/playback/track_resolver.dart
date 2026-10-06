import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hls/hls.dart';

import '../../../core/source/models.dart';
import 'playback_session_controller.dart';
import 'quality_label.dart';

typedef PlaylistFetcher = Future<String> Function(
  Uri uri,
  Map<String, String> headers,
);
typedef TrackRefresher = Future<List<VideoTrack>> Function();

/// [PlaylistFetcher] 的 dio 实现,外加一条属于它自己的生命周期。
///
/// 取清单要的是「给个 URL 和一组 headers,还我一段文本」,和共享的 `HttpService`
/// 那套 HostRequest/HostResponse 契约对不上,所以自带一个 dio。自带就要自己
/// [close]:一个 dio 背后是一条 HttpClient 连接池,每开一次播放页漏一个,
/// 看一晚上番就攒下几十条闲着的连接。
class DioPlaylistClient {
  DioPlaylistClient();

  final Dio _dio = Dio();
  bool _closed = false;

  bool get isClosed => _closed;

  Future<String> fetch(Uri uri, Map<String, String> headers) async {
    final response = await _dio.get<String>(
      uri.toString(),
      options: Options(
        headers: headers,
        responseType: ResponseType.plain,
      ),
    );
    return response.data ?? '';
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _dio.close(force: true);
  }
}

class TrackResolver implements PlaybackTrackProvider {
  TrackResolver({
    required PlaylistFetcher fetchPlaylist,
    required TrackRefresher refreshTracks,
  })  : _fetchPlaylist = fetchPlaylist,
        _refreshTracks = refreshTracks;

  final PlaylistFetcher _fetchPlaylist;
  final TrackRefresher _refreshTracks;
  final Map<String, int> _bandwidths = {};
  final Map<String, ({int? width, int? height})> _resolutions = {};

  Future<List<VideoTrack>> resolve(List<VideoTrack> sourceTracks) async {
    if (sourceTracks.length != 1 || !sourceTracks.single.hls) {
      return List.unmodifiable(sourceTracks);
    }
    final source = sourceTracks.single;
    final masterUri = _safeHttpUri(source.url);
    final headers =
        Map<String, String>.unmodifiable(source.headers ?? const {});
    final text = await _fetchPlaylist(masterUri, headers);
    final parsed = HlsParser.parse(text, baseUri: masterUri.resolve('.'));
    if (parsed is! HlsMasterPlaylist) return List.unmodifiable(sourceTracks);

    final master = HlsComposer.normalize(parsed) as HlsMasterPlaylist;
    final tiers = [
      for (final variant in master.variants)
        qualityTierLabel(width: variant.width, height: variant.height),
    ];
    final resolved = <VideoTrack>[];
    for (var index = 0; index < master.variants.length; index++) {
      final variant = master.variants[index];
      final uri = _safeHttpUri(variant.uri.toString());
      final bandwidth = variant.averageBandwidth ?? variant.bandwidth;
      final track = VideoTrack(
        url: uri.toString(),
        quality: _label(variant, tiers, index, bandwidth),
        headers: source.headers,
        hls: true,
        audioUrl: source.audioUrl,
      );
      resolved.add(track);
      _bandwidths[track.url] = bandwidth;
      _resolutions[track.url] = (
        width: variant.width,
        height: variant.height,
      );
    }
    if (resolved.isEmpty) throw const FormatException('HLS 主清单没有可用变体');
    return List.unmodifiable(resolved);
  }

  /// 变体的显示名:优先清晰度档,没有分辨率就退回码率。
  ///
  /// 两条变体归到同一档时(1920×1080 和 1920×800 都是 1080P)给两边都补上真实
  /// 分辨率 —— 否则面板上两行一模一样,而且刷新地址后 [matchRefreshed] 按名字
  /// 认轨道会认错那一条。
  static String _label(
    HlsVariant variant,
    List<String?> tiers,
    int index,
    int bandwidth,
  ) {
    final tier = tiers[index];
    if (tier == null) return '${(bandwidth / 1000).round()} kbps';
    var collides = false;
    for (var other = 0; other < tiers.length; other++) {
      if (other != index && tiers[other] == tier) collides = true;
    }
    if (!collides) return tier;
    final exact =
        exactResolution(width: variant.width, height: variant.height);
    return exact == null ? tier : '$tier · $exact';
  }

  int? bandwidthOf(VideoTrack track) => _bandwidths[track.url];

  ({int? width, int? height})? resolutionOf(VideoTrack track) =>
      _resolutions[track.url];

  @override
  Future<List<VideoTrack>> refresh() async => resolve(await _refreshTracks());

  @override
  VideoTrack? matchRefreshed(
    VideoTrack current,
    List<VideoTrack> refreshed,
  ) =>
      refreshed.where((track) => track.quality == current.quality).firstOrNull;

  @override
  VideoTrack? lowerQuality(
    VideoTrack current,
    List<VideoTrack> available,
  ) {
    final currentBandwidth = bandwidthOf(current);
    if (currentBandwidth == null) return null;
    final lower = available.where((track) {
      final bandwidth = bandwidthOf(track);
      return bandwidth != null && bandwidth < currentBandwidth;
    }).toList()
      ..sort(
          (left, right) => bandwidthOf(right)!.compareTo(bandwidthOf(left)!));
    return lower.firstOrNull;
  }

  @override
  VideoTrack? alternateLine(
    VideoTrack current,
    List<VideoTrack> available,
  ) =>
      available
          .where((track) =>
              track.url != current.url && track.quality == current.quality)
          .firstOrNull;

  static Uri _safeHttpUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('HLS 地址必须是无凭据的 HTTP(S) URL');
    }
    final host = uri.host.toLowerCase();
    final address = InternetAddress.tryParse(host);
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        (address?.isLoopback ?? false)) {
      throw const FormatException('HLS 地址不能指向回环网络');
    }
    return uri;
  }
}
