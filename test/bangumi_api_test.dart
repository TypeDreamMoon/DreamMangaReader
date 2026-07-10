import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/bangumi/bangumi_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 桩适配器:不发真请求,按 [handler] 返回预设响应。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);
  final ResponseBody Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  late HttpClientAdapter original;

  setUp(() => original = BangumiApi.dioForTesting.httpClientAdapter);
  tearDown(() => BangumiApi.dioForTesting.httpClientAdapter = original);

  void stub(ResponseBody Function(RequestOptions) handler) {
    BangumiApi.dioForTesting.httpClientAdapter = _StubAdapter(handler);
  }

  group('search', () {
    // 核心场景:bgm.tv 抖动(5xx/429)不能被当成「没搜到」——throwOnError
    // 调用方(推荐种子缓存)靠异常区分「暂时失败」,否则会写 24h 未命中缓存。
    test('5xx + throwOnError=true 抛出而不是当「没搜到」', () async {
      stub((_) => _json(503, {'error': 'Service Unavailable'}));
      await expectLater(BangumiApi.search('test', throwOnError: true),
          throwsA(isA<DioException>()));
    });

    test('429 + throwOnError=true 抛出', () async {
      stub((_) => _json(429, {'error': 'Too Many Requests'}));
      await expectLater(BangumiApi.search('test', throwOnError: true),
          throwsA(isA<DioException>()));
    });

    test('5xx + throwOnError=false 仍返回空(尽力而为调用方不受影响)', () async {
      stub((_) => _json(503, {'error': 'Service Unavailable'}));
      expect(await BangumiApi.search('test'), isEmpty);
    });

    test('200 正常解析候选', () async {
      stub((_) => _json(200, {
            'list': [
              {
                'id': 7157,
                'name': 'テスト',
                'name_cn': '测试作',
                'air_date': '2020-01-01',
                'rating': {'score': 7.8, 'total': 123},
              },
            ],
          }));
      final out = await BangumiApi.search('test', throwOnError: true);
      expect(out, hasLength(1));
      expect(out.first.id, 7157);
      expect(out.first.display, '测试作');
    });
  });

  group('fromId', () {
    test('404 = 条目不存在:即使 throwOnError=true 也返回 null(可缓存)', () async {
      stub((_) => _json(404, {'title': 'Not Found'}));
      expect(await BangumiApi.fromId(1, throwOnError: true), isNull);
    });

    test('5xx + throwOnError=true 抛出', () async {
      stub((_) => _json(503, {'title': 'Service Unavailable'}));
      await expectLater(
          BangumiApi.fromId(1, throwOnError: true), throwsA(isA<DioException>()));
    });

    test('5xx + throwOnError=false 仍返回 null', () async {
      stub((_) => _json(503, {'title': 'Service Unavailable'}));
      expect(await BangumiApi.fromId(1), isNull);
    });

    test('200 正常解析详情', () async {
      stub((_) => _json(200, {
            'id': 7157,
            'name': 'テスト',
            'name_cn': '测试作',
            'rating': {'score': 8.2, 'rank': 100, 'total': 500},
          }));
      final info = await BangumiApi.fromId(7157, throwOnError: true);
      expect(info, isNotNull);
      expect(info!.id, 7157);
      expect(info.name, '测试作');
      expect(info.score, 8.2);
    });
  });
}
