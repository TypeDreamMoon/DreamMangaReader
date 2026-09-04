import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 把一张图片交给系统相册(Android)。
///
/// 落点是 `DCIM/ScreenShot`。写应用私有目录也能成、还不用过原生这一趟,但
/// `/storage/emulated/0/Android/data/<包名>/files/…` 报给用户等于没报 —— 相册里
/// 永远不出现,路径长到念不完。
class AndroidGalleryBridge {
  AndroidGalleryBridge({
    this.channel = const MethodChannel('dream_manga_reader/gallery'),
    bool? enabled,
  }) : enabled = enabled ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel channel;
  final bool enabled;

  /// 存好之后返回给人看的相册内路径(`DCIM/ScreenShot/xxx.jpg`)。
  ///
  /// 这个平台没有相册就返回 null —— 让调用方去落自己的目录,而不是把「不支持」
  /// 当成失败报给用户。真存失败了才抛。
  Future<String?> saveImage({
    required Uint8List bytes,
    required String fileName,
    String mimeType = 'image/jpeg',
  }) async {
    if (!enabled) return null;
    return channel.invokeMethod<String>('saveImage', <String, Object?>{
      'bytes': bytes,
      'fileName': fileName,
      'mimeType': mimeType,
    });
  }
}
