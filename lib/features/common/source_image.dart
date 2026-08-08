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
  final void Function(Object error)? onError;

  @override
  Widget build(BuildContext context) {
    if (isPageImageDataUri(source)) {
      try {
        final data = decodePageImageDataUri(source);
        return Image.memory(
          data.bytes,
          fit: fit,
          gaplessPlayback: true,
          errorBuilder: (_, error, __) {
            onError?.call(error);
            return fallback;
          },
        );
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
      placeholder: (_, __) => fallback,
      errorWidget: (_, __, ___) => fallback,
      errorListener: onError,
    );
  }
}
