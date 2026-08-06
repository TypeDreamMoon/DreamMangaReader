import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/features/reader/retryable_reader_network_image.dart';

const _url = 'https://example.test/page.png';
const _onePixelPng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

class _RetryCacheManager implements BaseCacheManager {
  final _fileSystem = MemoryFileSystem();
  int loads = 0;
  int removes = 0;
  Completer<void>? removeBarrier;
  final loadHeaders = <Map<String, String>?>[];

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    loads++;
    loadHeaders.add(headers == null ? null : Map.of(headers));
    final bytes = loads == 1 ? <int>[0, 1, 2, 3] : base64Decode(_onePixelPng);
    final file = _fileSystem.systemTempDirectory.childFile('page-$loads.png');
    await file.writeAsBytes(bytes);
    yield FileInfo(
      file,
      FileSource.Online,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }

  @override
  Future<void> removeFile(String key) async {
    removes++;
    await removeBarrier?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(_RetryCacheManager cacheManager) => MaterialApp(
      home: Scaffold(
        body: RetryableReaderNetworkImage(
          imageUrl: _url,
          httpHeaders: const {'Referer': 'https://example.test/'},
          cacheManager: cacheManager,
          fit: BoxFit.contain,
          width: 320,
          height: 480,
          progressIndicatorBuilder: (_, __) =>
              const SizedBox(key: Key('reader-image-loading')),
          errorWidgetBuilder: (_, retrying) => SizedBox(
            key: Key(
              retrying ? 'reader-image-retrying' : 'reader-image-retry',
            ),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  testWidgets('tap evicts only the failed image and retries successfully',
      (tester) async {
    final cacheManager = _RetryCacheManager();
    await tester.pumpWidget(_host(cacheManager));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reader-image-retry')), findsOneWidget);
    expect(cacheManager.loads, 1);

    await tester.tap(
      find.byKey(const Key('reader-network-image-retry-target')),
    );
    await tester.pumpAndSettle();

    expect(cacheManager.removes, 1);
    expect(cacheManager.loads, 2);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.byKey(const Key('reader-image-retry')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry ignores repeated taps and preserves image parameters',
      (tester) async {
    final cacheManager = _RetryCacheManager();
    await tester.pumpWidget(_host(cacheManager));
    await tester.pumpAndSettle();

    cacheManager.removeBarrier = Completer<void>();
    final retryTarget = find.byKey(
      const Key('reader-network-image-retry-target'),
    );
    await tester.tap(retryTarget);
    await tester.pump();

    final disabledTarget = tester.widget<GestureDetector>(retryTarget);
    expect(disabledTarget.onTap, isNull);
    await tester.tap(retryTarget, warnIfMissed: false);
    await tester.pump();

    expect(cacheManager.removes, 1);
    expect(cacheManager.loads, 1);

    cacheManager.removeBarrier!.complete();
    await tester.pumpAndSettle();

    expect(cacheManager.loads, 2);
    expect(cacheManager.loadHeaders, const [
      {'Referer': 'https://example.test/'},
      {'Referer': 'https://example.test/'},
    ]);
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.fit, BoxFit.contain);
    expect(image.width, 320);
    expect(image.height, 480);
  });
}
