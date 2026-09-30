import 'dart:io';

import '../../core/local/local_models.dart';
import '../../core/source/models.dart';

/// 把本地条目变成播放内核认得的 [VideoTrack]。
///
/// 三条硬性规则(设计规格 §6.1),每一条都有踩过的坑:
///
/// 1. **必须是 `Uri.file(...)` 的 `file:` URL**,不能直接塞裸路径。裸路径
///    (`F:\a\b.mkv`) 不是合法 URL,而播放层统一用 `url.startsWith('file:')`
///    判断本地(anime_player_page.dart:190),裸路径会被当成远端。
/// 2. **`hls` 恒为 `false`**。`hls: true` 会让 `MediaKitPlayerAdapter` 走
///    `HlsCacheGateway`,而网关对非 HLS 直接 `ArgumentError('不是 HLS')`。
/// 3. **`headers` 恒为 `null`**,本地文件不经过 `MpvNetworkOptions`。
///
/// Android 的 `content://` URI **不能**进这里:桥会把「怎么打开」收敛成
/// 一个可播 URL(路线 A 的 `/proc/self/fd/N`,或路线 B 导入后的真实路径),
/// 播放层不认识 `content://`。
VideoTrack buildLocalTrack(
  LocalMediaItem item, {
  List<LocalSubtitle>? subtitles,
  required String qualityLabel,
  bool? windows,
}) {
  final location = item.location.trim();
  if (location.isEmpty) {
    throw ArgumentError('本地条目缺少文件位置: ${item.id}');
  }
  if (location.startsWith('content://')) {
    throw ArgumentError(
      '本地 track 不接受 content:// URI,请先经 LocalMediaBridge 换成可播路径: $location',
    );
  }
  final isWindows = windows ?? Platform.isWindows;
  final files = subtitles ?? item.subtitles;
  return VideoTrack(
    url: Uri.file(location, windows: isWindows).toString(),
    quality: qualityLabel,
    headers: null,
    hls: false,
    audioUrl: null,
    subtitles: [
      for (final subtitle in files)
        if (subtitle.location.trim().isNotEmpty)
          SubtitleAsset(
            url: Uri.file(subtitle.location.trim(), windows: isWindows)
                .toString(),
            label: subtitle.label,
            language: subtitle.language,
          ),
    ],
  );
}
