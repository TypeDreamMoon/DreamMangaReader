import 'package:dio/dio.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fault_http_server.dart';

void main() {
  group('HlsUpstreamPolicy', () {
    const policy = HlsUpstreamPolicy();

    test('accepts public HTTP(S) hosts', () {
      expect(policy.validate(Uri.parse('https://cdn.example.com/a.m3u8')).host,
          'cdn.example.com');
      expect(policy.validate(Uri.parse('http://203.0.113.7/a.ts')).host,
          '203.0.113.7');
    });

    test('rejects non-HTTP schemes and embedded credentials', () {
      expect(() => policy.validate(Uri.parse('file:///etc/passwd')),
          throwsA(isA<FormatException>()));
      expect(() => policy.validate(Uri.parse('https://u:p@example.com/a.ts')),
          throwsA(isA<FormatException>()));
    });

    test('rejects loopback by name and by literal address', () {
      for (final url in [
        'http://localhost:8080/a.ts',
        'http://sub.localhost/a.ts',
        'http://127.0.0.1/a.ts',
        'http://127.9.9.9/a.ts',
        'http://[::1]/a.ts',
      ]) {
        expect(() => policy.validate(Uri.parse(url)),
            throwsA(isA<FormatException>()), reason: url);
      }
    });

    test('rejects private, link-local, CGNAT and metadata addresses', () {
      for (final url in [
        'http://10.0.0.5/a.ts',
        'http://172.16.3.4/a.ts',
        'http://172.31.255.1/a.ts',
        'http://192.168.1.1/a.ts',
        'http://169.254.169.254/latest/meta-data/', // 云元数据端点
        'http://100.64.0.1/a.ts',
        'http://0.0.0.0/a.ts',
        'http://[fc00::1]/a.ts',
        'http://[fe80::1]/a.ts',
        'http://[::ffff:192.168.0.1]/a.ts', // IPv4 映射地址
      ]) {
        expect(() => policy.validate(Uri.parse(url)),
            throwsA(isA<FormatException>()), reason: url);
      }
    });

    test('allows loopback only when explicitly opted in', () {
      const permissive = HlsUpstreamPolicy(allowLoopback: true);
      expect(permissive.validate(Uri.parse('http://127.0.0.1:9/a.ts')).port, 9);
    });
  });

  group('DioHlsUpstreamClient redirects', () {
    late FaultHttpServer server;

    setUp(() async => server = await FaultHttpServer.start());
    tearDown(() async => server.close());

    test('re-validates each hop instead of trusting Dio auto-redirect',
        () async {
      // 上游把请求跳到回环地址。自动跟随重定向会让准入策略形同虚设。
      server.addRedirect('/seg.ts', 'http://127.0.0.1:1/internal');
      final client = DioHlsUpstreamClient(Dio());

      await expectLater(
        client.get(server.baseUri.resolve('/seg.ts'), headers: const {}),
        throwsA(isA<FormatException>()),
      );
    });

    test('follows same-host redirects and keeps credential headers', () async {
      server.addRedirect('/a.ts', '/b.ts');
      server.addBytes('/b.ts', const [1, 2, 3]);
      final client = DioHlsUpstreamClient(
        Dio(),
        policy: const HlsUpstreamPolicy(allowLoopback: true),
      );

      final response = await client.get(
        server.baseUri.resolve('/a.ts'),
        headers: const {'Authorization': 'Bearer keep-me'},
      );

      expect(response.statusCode, 200);
      expect(response.bytes, const [1, 2, 3]);
      final hop = server.requests.last;
      expect(hop.path, '/b.ts');
      expect(hop.authorization, 'Bearer keep-me');
    });

    test('drops credential headers when a redirect changes host', () async {
      // 换主机名(localhost 与 127.0.0.1 是同一台机器但不同 host 串)后不得再带凭据。
      server.addRedirect('/a.ts', 'http://localhost:${server.baseUri.port}/b.ts');
      server.addBytes('/b.ts', const [9]);
      final client = DioHlsUpstreamClient(
        Dio(),
        policy: const HlsUpstreamPolicy(allowLoopback: true),
      );

      final response = await client.get(
        server.baseUri.resolve('/a.ts'),
        headers: const {'Authorization': 'Bearer leak-me'},
      );

      expect(response.statusCode, 200);
      final hop = server.requests.last;
      expect(hop.path, '/b.ts');
      expect(hop.authorization, isNull);
    });

    test('gives up after too many redirects', () async {
      server.addRedirect('/loop.ts', '/loop.ts');
      final client = DioHlsUpstreamClient(
        Dio(),
        policy: const HlsUpstreamPolicy(allowLoopback: true),
        maxRedirects: 2,
      );

      await expectLater(
        client.get(server.baseUri.resolve('/loop.ts'), headers: const {}),
        throwsA(isA<FormatException>()),
      );
      expect(server.requestCount('/loop.ts'), 3); // 首请求 + 2 跳
    });
  });
}
