import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/bili/bili_auth.dart';
import 'package:dream_manga_reader/core/bili/bili_errors.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定回一个响应体的 dio 传输层。
class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.body, {this.status = 200, this.json = true});

  final String body;
  final int status;
  final bool json;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: [
            json ? Headers.jsonContentType : Headers.textPlainContentType,
          ],
        },
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  tearDown(() => BiliAuth.debugAdapter = null);

  test('a well formed qrcode envelope still yields url and key', () async {
    BiliAuth.debugAdapter = _FixedAdapter(jsonEncode({
      'code': 0,
      'data': {
        'url': 'https://passport.bilibili.com/qrcode/h5/login?oauthKey=abc',
        'qrcode_key': 'abc123',
      },
    }));

    final qr = await BiliAuth.instance.qrGenerate();

    expect(qr.key, 'abc123');
    expect(qr.url, contains('oauthKey=abc'));
  });

  // 风控/降级时接口回的信封里根本没有 data。裸 cast 抛的是一句
  // 「type 'Null' is not a subtype of type 'Map'」,登录页原样贴给用户看。
  test('a rate limited qrcode envelope becomes a classified BiliException',
      () async {
    BiliAuth.debugAdapter = _FixedAdapter(jsonEncode({
      'code': -412,
      'message': '请求被拦截',
      'data': null,
    }));

    await expectLater(
      BiliAuth.instance.qrGenerate(),
      throwsA(isA<BiliException>()
          .having((e) => e.failure, 'failure', BiliFailure.rateLimited)
          .having((e) => e.code, 'code', -412)),
    );
  });

  test('a non JSON qrcode response becomes a BiliException, not a cast error',
      () async {
    BiliAuth.debugAdapter = _FixedAdapter(
      '<html><body>404</body></html>',
      status: 404,
      json: false,
    );

    await expectLater(
      BiliAuth.instance.qrGenerate(),
      throwsA(isA<BiliException>()
          .having((e) => e.detail, 'detail', contains('二维码接口'))),
    );
  });

  test('an envelope without qrcode_key is rejected with an explanation',
      () async {
    BiliAuth.debugAdapter = _FixedAdapter(jsonEncode({
      'code': 0,
      'data': {'url': 'https://passport.bilibili.com/qrcode/h5/login'},
    }));

    await expectLater(
      BiliAuth.instance.qrGenerate(),
      throwsA(isA<BiliException>()
          .having((e) => e.detail, 'detail', contains('qrcode_key'))),
    );
  });
}
