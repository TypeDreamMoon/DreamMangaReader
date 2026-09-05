import 'dart:io';

import 'package:dream_manga_reader/core/net/app_proxy.dart';
import 'package:dream_manga_reader/core/net/image_cache.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubResponse implements FileServiceResponse {
  @override
  Stream<List<int>> get content => const Stream.empty();
  @override
  int? get contentLength => 0;
  @override
  String? get eTag => null;
  @override
  String get fileExtension => '.jpg';
  @override
  int get statusCode => 200;
  @override
  DateTime get validTill => DateTime.now();
}

class _StubService extends FileService {
  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async =>
      _StubResponse();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // AppProxy.refresh 会写 HttpOverrides.global(进程级),别把它留给后面的测试。
  tearDown(() {
    HttpOverrides.global = null;
  });

  group('proxy generation', () {
    test('每次 refresh 递增,让长命 client 知道自己过期了', () async {
      final before = AppProxy.generation;
      await AppProxy.setOverride('DIRECT');
      expect(AppProxy.generation, greaterThan(before));
      final middle = AppProxy.generation;
      await AppProxy.setOverride('127.0.0.1:7890');
      expect(AppProxy.generation, greaterThan(middle));
    });
  });

  group('image file service', () {
    test('同一代理世代下复用同一个下载器', () async {
      final created = <FileService>[];
      final service = ProxyAwareImageService(createDelegate: () {
        final stub = _StubService();
        created.add(stub);
        return stub;
      });

      await service.get('https://example.com/a.jpg');
      await service.get('https://example.com/b.jpg');

      expect(created, hasLength(1));
    });

    test('改了代理之后重建下载器,不再走旧代理', () async {
      final created = <FileService>[];
      final service = ProxyAwareImageService(createDelegate: () {
        final stub = _StubService();
        created.add(stub);
        return stub;
      });

      await AppProxy.setOverride('127.0.0.1:7890');
      await service.get('https://example.com/a.jpg');
      expect(created, hasLength(1));

      // HttpClient 只在构造那一刻读 HttpOverrides.global,所以改代理必须换 client。
      await AppProxy.setOverride('DIRECT');
      await service.get('https://example.com/b.jpg');
      expect(created, hasLength(2));
      expect(created[0], isNot(same(created[1])));
    });
  });
}
