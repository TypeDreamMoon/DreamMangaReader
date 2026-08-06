import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/features/anime/playback/hls_cache_settings.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<CacheDownloadResult> _write(
  File file,
  List<int> bytes, {
  int? expectedLength,
}) async {
  await file.writeAsBytes(bytes, flush: true);
  return CacheDownloadResult(
    contentType: 'video/mp2t',
    expectedLength: expectedLength ?? bytes.length,
  );
}

void main() {
  late Directory temp;
  late DateTime now;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dmr-hls-cache-test-');
    now = DateTime.utc(2026, 8, 5);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('deduplicates concurrent downloads and serves later cache hits',
      () async {
    final store = HlsCacheStore(
      directory: temp,
      limitBytes: 1024,
      now: () => now,
    );
    const request = HlsCacheRequest(
      url: 'https://media.example.test/000.ts',
      authScope: 'xiaojie_github',
    );
    final gate = Completer<void>();
    final started = Completer<void>();
    var downloads = 0;
    Future<CacheDownloadResult> download(File file) async {
      downloads++;
      if (!started.isCompleted) started.complete();
      await gate.future;
      return _write(file, [1, 2, 3, 4]);
    }

    final firstFuture = store.acquire(request, download);
    final secondFuture = store.acquire(request, download);
    await started.future;
    expect(downloads, 1);
    gate.complete();
    final first = await firstFuture;
    final second = await secondFuture;
    expect(await first.file.readAsBytes(), [1, 2, 3, 4]);
    await first.release();
    await second.release();

    final hit = await store.acquire(request, (_) {
      fail('a cache hit must not download');
    });
    expect(downloads, 1);
    await hit.release();
  });

  test('cleans temporary files and rejects incomplete downloads', () async {
    await File('${temp.path}/orphan.tmp').writeAsBytes([9]);
    final store = HlsCacheStore(directory: temp, limitBytes: 1024);
    await store.initialize();
    expect(await File('${temp.path}/orphan.tmp').exists(), isFalse);

    await expectLater(
      store.acquire(
        const HlsCacheRequest(
          url: 'https://media.example.test/short.m4s',
          authScope: 'public',
          rangeStart: 720,
          rangeLength: 2800,
        ),
        (file) => _write(file, [1, 2], expectedLength: 3),
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      temp
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.bin')),
      isEmpty,
    );
  });

  test('evicts least recently used entries and protects active leases',
      () async {
    final store = HlsCacheStore(
      directory: temp,
      limitBytes: 6,
      now: () => now,
    );
    Future<HlsCacheLease> add(String name) => store.acquire(
          HlsCacheRequest(
            url: 'https://media.example.test/$name.ts',
            authScope: 'public',
          ),
          (file) => _write(file, [1, 2, 3, 4]),
        );

    final active = await add('active');
    now = now.add(const Duration(seconds: 1));
    final second = await add('second');
    expect(await active.file.exists(), isTrue);
    expect(await second.file.exists(), isTrue);
    await second.release();
    expect(await second.file.exists(), isFalse);

    await active.release();
    now = now.add(const Duration(seconds: 1));
    final third = await add('third');
    expect(await active.file.exists(), isFalse);
    expect(await third.file.exists(), isTrue);
    await third.release();
  });

  test('cache metadata and paths never contain URL or token material',
      () async {
    const sentinel = 'DO_NOT_PERSIST_TOKEN_91f4';
    final store = HlsCacheStore(directory: temp, limitBytes: 1024);
    final lease = await store.acquire(
      const HlsCacheRequest(
        url: 'https://media.example.test/segment.ts?signature=private-value',
        authScope: 'xiaojie_github',
      ),
      (file) => _write(file, [1, 2, 3]),
    );
    await lease.release();

    final names = temp.listSync().map((entry) => entry.path).join('\n');
    final index = await File('${temp.path}/index.json').readAsString();
    expect(names, isNot(contains('media.example.test')));
    expect(names, isNot(contains('private-value')));
    expect(index, isNot(contains('media.example.test')));
    expect(index, isNot(contains('private-value')));
    expect(index, isNot(contains(sentinel)));
    expect(jsonDecode(index), isA<Map<String, dynamic>>());
  });

  test('exposes only the approved cache limits', () {
    expect(HlsCacheLimit.off.bytes, 0);
    expect(HlsCacheLimit.mib256.bytes, 256 * 1024 * 1024);
    expect(HlsCacheLimit.mib512.bytes, 512 * 1024 * 1024);
    expect(HlsCacheLimit.gib1.bytes, 1024 * 1024 * 1024);
    expect(HlsCacheLimit.defaultValue, HlsCacheLimit.mib512);
  });
}
