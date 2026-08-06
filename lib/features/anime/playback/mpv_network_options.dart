import '../../../core/source/models.dart';

const String kAnimeBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

class MpvNetworkOptions {
  const MpvNetworkOptions._({
    required this.userAgent,
    required this.httpProxy,
  }) : networkTimeoutSeconds = 15;

  static const List<String> protocolWhitelist = [
    'file',
    'crypto',
    'data',
    'http',
    'https',
    'tcp',
    'tls',
    'httpproxy',
    'hls',
    'applehttp',
  ];

  final String userAgent;
  final String? httpProxy;
  final int networkTimeoutSeconds;

  String get streamLavf =>
      'protocol_whitelist=[${protocolWhitelist.join(',')}]';

  String get demuxerLavf => [
        'seg_max_retry=5',
        'strict=experimental',
        'allowed_extensions=ALL',
        streamLavf,
      ].join(',');

  static MpvNetworkOptions forTrack(VideoTrack track, {String? proxy}) {
    final userAgent = track.headers?.entries
            .where((entry) => entry.key.toLowerCase() == 'user-agent')
            .map((entry) => entry.value.trim())
            .where((value) => value.isNotEmpty)
            .firstOrNull ??
        kAnimeBrowserUserAgent;
    return MpvNetworkOptions._(
      userAgent: userAgent,
      httpProxy: _normalizeProxy(proxy),
    );
  }

  static String? _normalizeProxy(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host.isEmpty ||
        uri.port == 0 ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('无效的 HTTP 代理地址');
    }
    return 'http://${uri.host}:${uri.port}';
  }
}
