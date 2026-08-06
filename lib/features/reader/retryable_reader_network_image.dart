import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

typedef ReaderImageProgressBuilder = Widget Function(
  BuildContext context,
  DownloadProgress progress,
);

typedef ReaderImageErrorBuilder = Widget Function(
  BuildContext context,
  bool retrying,
);

class RetryableReaderNetworkImage extends StatefulWidget {
  const RetryableReaderNetworkImage({
    super.key,
    required this.imageUrl,
    required this.httpHeaders,
    required this.cacheManager,
    required this.fit,
    required this.progressIndicatorBuilder,
    required this.errorWidgetBuilder,
    this.width,
    this.height,
  });

  final String imageUrl;
  final Map<String, String> httpHeaders;
  final BaseCacheManager cacheManager;
  final BoxFit fit;
  final double? width;
  final double? height;
  final ReaderImageProgressBuilder progressIndicatorBuilder;
  final ReaderImageErrorBuilder errorWidgetBuilder;

  @override
  State<RetryableReaderNetworkImage> createState() =>
      _RetryableReaderNetworkImageState();
}

class _RetryableReaderNetworkImageState
    extends State<RetryableReaderNetworkImage> {
  int _attempt = 0;
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await CachedNetworkImage.evictFromCache(
        widget.imageUrl,
        cacheManager: widget.cacheManager,
      );
    } catch (_) {
      // A new attempt can still recover when cache eviction fails.
    }
    if (!mounted) return;
    setState(() {
      _retrying = false;
      _attempt++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      key: ValueKey('${widget.imageUrl}#$_attempt'),
      cacheManager: widget.cacheManager,
      imageUrl: widget.imageUrl,
      httpHeaders: widget.httpHeaders,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      fadeInDuration: const Duration(milliseconds: 120),
      progressIndicatorBuilder: (_, __, progress) =>
          widget.progressIndicatorBuilder(context, progress),
      errorWidget: (_, __, ___) => GestureDetector(
        key: const Key('reader-network-image-retry-target'),
        behavior: HitTestBehavior.opaque,
        onTap: _retrying ? null : _retry,
        child: widget.errorWidgetBuilder(context, _retrying),
      ),
    );
  }
}
