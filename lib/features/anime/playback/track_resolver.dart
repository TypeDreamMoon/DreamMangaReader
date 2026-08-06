import 'dart:io';

import 'package:hls/hls.dart';

import '../../../core/source/models.dart';
import 'playback_session_controller.dart';

typedef PlaylistFetcher = Future<String> Function(
  Uri uri,
  Map<String, String> headers,
);
typedef TrackRefresher = Future<List<VideoTrack>> Function();

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
    final resolved = <VideoTrack>[];
    for (final variant in master.variants) {
      final uri = _safeHttpUri(variant.uri.toString());
      final bandwidth = variant.averageBandwidth ?? variant.bandwidth;
      final label = variant.height == null
          ? '${(bandwidth / 1000).round()} kbps'
          : '${variant.height}p';
      final track = VideoTrack(
        url: uri.toString(),
        quality: label,
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
