import 'package:dream_manga_reader/core/bili/bili_errors.dart';
import 'package:flutter_test/flutter_test.dart';

/// 归类的重点是**给用户一个能行动的结论**,而不是把接口的 code 原样抛出去。
void main() {
  test('地区限制:码和文案任一命中都算', () {
    expect(biliFailureOf(-10403, null), BiliFailure.geoBlocked);
    expect(biliFailureOf(null, '抱歉,此视频仅限中国大陆地区观看'),
        BiliFailure.geoBlocked);
    // Bstation 按 s_locale 返回繁中 / 英文,三种都得认。
    expect(biliFailureOf(null, '非常抱歉，根據版權方要求，您所在地區無法觀看本片'),
        BiliFailure.geoBlocked);
    expect(biliFailureOf(null, 'This content is not available in your region'),
        BiliFailure.geoBlocked);
  });

  // -404 被复用得很凶:既是「没这个番」,也是「你这地区没有」。
  // 光看码会把地区限制误报成「已下架」,让用户以为挂代理也没用。
  test('同一个 -404,带地区文案时算锁区,不带才算没有', () {
    expect(biliFailureOf(-404, '啥都木有'), BiliFailure.notFound);
    expect(biliFailureOf(-404, '该地区不可观看'), BiliFailure.geoBlocked);
  });

  test('大会员与未登录各归各的', () {
    expect(biliFailureOf(87008, null), BiliFailure.vipOnly);
    expect(biliFailureOf(null, '大会员专享'), BiliFailure.vipOnly);
    expect(biliFailureOf(-101, null), BiliFailure.needsLogin);
    expect(biliFailureOf(null, '请先登录'), BiliFailure.needsLogin);
    // Bstation 播放接口未登录时的实测码。
    expect(biliFailureOf(10004001, null), BiliFailure.needsLogin);
    expect(biliFailureOf(10004004, null), BiliFailure.needsLogin);
  });

  test('风控拦截单独一类,不该跟锁区混', () {
    expect(biliFailureOf(-412, null), BiliFailure.rateLimited);
  });

  test('归不了类就保留原始信息,别把排查线索吃掉', () {
    final e = biliExceptionOf(const {'code': -999, 'message': '未知错误'});
    expect(e.failure, BiliFailure.unknown);
    expect(e.code, -999);
    expect(e.detail, '未知错误');
    expect('$e', contains('-999'));
  });

  test('code 是字符串也认', () {
    expect(biliExceptionOf(const {'code': '-10403'}).failure,
        BiliFailure.geoBlocked);
  });

  test('空响应体不炸', () {
    final e = biliExceptionOf(const {});
    expect(e.failure, BiliFailure.unknown);
    expect(e.code, isNull);
  });
}
