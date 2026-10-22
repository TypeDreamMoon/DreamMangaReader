import 'dart:io';

import '../../core/local/local_models.dart';
import '../../core/source/models.dart';

/// 把本地条目变成播放内核认得的 [VideoTrack]。
///
/// 三条硬性规则(设计规格 §6.1),每一条都有踩过的坑:
///
/// 1. **必须是播放内核认得的 URL**,不能直接塞裸路径。裸路径
///    (`F:\a\b.mkv`) 不是合法 URL;真实路径统一走 `Uri.file(...)`。
///    例外是 Android 的 `fd://<fd>`(SAF 描述符,见 [OpenedLocalFd.playUrl]):
///    它是 mpv 自己的协议,原样透传 —— 不能再 `Uri.file` 包一层。
/// 2. **`hls` 恒为 `false`**。`hls: true` 会让 `MediaKitPlayerAdapter` 走
///    `HlsCacheGateway`,而网关对非 HLS 直接 `ArgumentError('不是 HLS')`。
/// 3. **`headers` 恒为 `null`**,本地文件不经过 `MpvNetworkOptions`。
///
/// Android 的 `content://` URI **不能**进这里:桥会把「怎么打开」收敛成
/// 一个可播地址(`fd://<fd>`,或 Windows 上导入后的真实路径),
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
      '本地 track 不接受 content:// URI,请先经 LocalMediaBridge 换成可播地址: $location',
    );
  }
  final isWindows = windows ?? Platform.isWindows;
  final files = subtitles ?? item.subtitles;
  return VideoTrack(
    url: localPlayableUrl(location, windows: isWindows),
    quality: qualityLabel,
    headers: null,
    hls: false,
    audioUrl: null,
    subtitles: [
      for (final subtitle in files)
        if (subtitle.location.trim().isNotEmpty)
          SubtitleAsset(
            url: localPlayableUrl(subtitle.location.trim(), windows: isWindows),
            label: subtitle.label,
            language: subtitle.language,
          ),
    ],
  );
}

/// 位置 → 播放内核认得的地址。
///
/// - 真实路径(Windows 绝对路径、Android 路线 B 导入后的路径)→ `file:` URL;
/// - `fd://<fd>`(Android 路线 A:SAF 描述符)→ 原样透传。mpv 的 fd 协议直接
///   dup 描述符读写,不经过路径解析 —— 用 `/proc/self/fd/<fd>` 的话,内核会按目标
///   路径重新检查权限,作用域存储下直接 EACCES(真机实测)。
String localPlayableUrl(String location, {required bool windows}) {
  if (location.startsWith('fd://')) return location;
  return Uri.file(location, windows: windows).toString();
}
