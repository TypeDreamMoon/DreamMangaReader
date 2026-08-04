import 'dart:io';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/page_image_data.dart';
import 'package:flutter_test/flutter_test.dart';

const onePixelPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download-page-writer-');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('writes data pages without calling the network cache', () async {
    final output = File('${temp.path}/0.img');
    var networkCalls = 0;

    await writePageImage(
      image: const PageImage(index: 0, url: onePixelPng),
      output: output,
      headers: const {'Referer': 'https://example.test/'},
      fetchNetwork: (url, headers) async {
        networkCalls++;
        throw StateError('network should not run');
      },
    );

    expect(networkCalls, 0);
    expect(await output.readAsBytes(), decodePageImageDataUri(onePixelPng).bytes);
  });

  test('copies HTTP pages returned by the network cache', () async {
    final cached = File('${temp.path}/cached.webp');
    await cached.writeAsBytes([1, 2, 3]);
    final output = File('${temp.path}/network.img');
    Map<String, String>? seenHeaders;

    await writePageImage(
      image: const PageImage(index: 0, url: 'https://img.test/page.webp'),
      output: output,
      headers: const {'Referer': 'https://site.test/'},
      fetchNetwork: (url, headers) async {
        expect(url, 'https://img.test/page.webp');
        seenHeaders = headers;
        return cached;
      },
    );

    expect(seenHeaders, {'Referer': 'https://site.test/'});
    expect(await output.readAsBytes(), [1, 2, 3]);
  });

  test('copies local pages without calling the network cache', () async {
    final local = File('${temp.path}/local.img');
    await local.writeAsBytes([4, 5, 6]);
    final output = File('${temp.path}/copied.img');
    var networkCalls = 0;

    await writePageImage(
      image: PageImage(index: 0, url: local.path),
      output: output,
      headers: const {},
      fetchNetwork: (url, headers) async {
        networkCalls++;
        throw StateError('network should not run');
      },
    );

    expect(networkCalls, 0);
    expect(await output.readAsBytes(), [4, 5, 6]);
  });
}
