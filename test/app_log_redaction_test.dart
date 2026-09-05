import 'package:dream_manga_reader/core/log/app_log.dart';
import 'package:flutter_test/flutter_test.dart';

// 网络日志的 detail 之前放原样 URL。日志页可以整份复制发给作者反馈问题,等于把
// 图源/更新包地址上的签名参数和 `user:pass@host` 一起发出去。落盘前必须脱敏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppLog.i.clear);

  LogEntry lastEntry() => AppLog.i.entries.last;

  test('logHttp stores a redacted URL in the detail line', () {
    logHttp(
      'GET',
      'https://cdn.example.com/ch/1.jpg?token=abc123&ts=1700000000&w=800',
      200,
      2048,
      12,
    );

    final detail = lastEntry().detail!;
    expect(detail, 'https://cdn.example.com/ch/1.jpg');
    expect(detail, isNot(contains('abc123')));
    expect(detail, isNot(contains('token')));
  });

  test('logHttpError redacts both the URL and the error text', () {
    logHttpError(
      'GET',
      'https://gitee.com/pkg.apk?sign=deadbeef',
      340,
      'DioException: connection closed '
          'https://gitee.com/pkg.apk?sign=deadbeef',
    );

    final detail = lastEntry().detail!;
    expect(detail, isNot(contains('deadbeef')));
    expect(detail, contains('https://gitee.com/pkg.apk'));
    expect(detail, contains('connection closed'));
  });

  test('shortUrl drops userinfo so the headline never leaks a password', () {
    expect(
      shortUrl('https://alice:s3cret@dav.example.com/dmr/sync.json'),
      'dav.example.com/dmr/sync.json',
    );
    // 路径里的 @ 不能被误当成 userinfo 分隔符。
    expect(shortUrl('https://example.com/u/@bob/feed'), 'example.com/u/@bob/feed');
  });

  test('logHttp headline and copied transcript carry no credentials', () {
    logHttp(
      'PUT',
      'https://alice:s3cret@dav.example.com/dmr/sync.json?key=topsecret',
      201,
      10,
      5,
    );

    final text = AppLog.i.asText();
    expect(text, isNot(contains('s3cret')));
    expect(text, isNot(contains('topsecret')));
    expect(text, contains('dav.example.com/dmr/sync.json'));
  });
}
