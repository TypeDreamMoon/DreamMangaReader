import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/net/image_cache.dart';
import '../../core/source/page_image_data.dart';

/// Displays source-provided raster images from either an authenticated network
/// URL or an inline Base64 data URI used by private sources.
class SourceImage extends StatelessWidget {
  const SourceImage({
    super.key,
    required this.source,
    required this.fallback,
    this.placeholder,
    this.headers,
    this.fit = BoxFit.cover,
    this.fadeInDuration = const Duration(milliseconds: 180),
    this.onError,
  });

  final String source;
  final Map<String, String>? headers;
  final BoxFit fit;
  final Duration fadeInDuration;
  final Widget fallback;

  /// 加载中显示的内容;为空时退回 [fallback](与既有观感一致)。
  ///
  /// 单列出来是为了**让贵的占位只在加载期间存在**:封面卡片的占位是渐变 + 网点 +
  /// 首字,网点一次要画上千个点(实测占书架滚动光栅开销的大头)。之前占位始终画在
  /// 图片底下,图加载完也照画不误 —— 传进来当 placeholder 之后,加载完它就不在
  /// 显示列表里了,滚动时不再为看不见的东西买单。
  final Widget? placeholder;
  final void Function(Object error)? onError;

  @override
  Widget build(BuildContext context) {
    if (isPageImageDataUri(source)) {
      try {
        final data = decodePageImageDataUri(source);
        final under = placeholder;
        final image = Image.memory(
          data.bytes,
          fit: fit,
          gaplessPlayback: true,
          // 内存解码这条没有「加载完成」回调,用 frameBuilder 判断首帧出来没有:
          // 出来了就把占位摘掉,别让它在图片底下白画一辈子(与网络那条同一原则)。
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (under == null || wasSynchronouslyLoaded || frame != null) {
              return child;
            }
            return Stack(fit: StackFit.expand, children: [under, child]);
          },
          errorBuilder: (_, error, __) {
            onError?.call(error);
            return fallback;
          },
        );
        return image;
      } on Object catch (error) {
        onError?.call(error);
        return fallback;
      }
    }

    return CachedNetworkImage(
      cacheManager: appImageCache,
      imageUrl: source,
      httpHeaders: headers,
      fit: fit,
      fadeInDuration: fadeInDuration,
      placeholder: (_, __) => placeholder ?? fallback,
      errorWidget: (_, __, ___) => fallback,
      errorListener: onError,
    );
  }
}
