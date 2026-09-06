import 'dart:convert';

import 'package:dream_manga_reader/core/net/webview_fetch.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebViewNavigation', () {
    test('POST 保留方法与 body,不降级成 GET', () {
      final nav = WebViewNavigation.of(method: 'post', body: '{"page":2}');
      expect(nav.method, 'POST');
      expect(nav.body, '{"page":2}');
      final req = nav.toUrlRequest('https://example.com/api');
      expect(req.method, 'POST');
      expect(utf8.decode(req.body!), '{"page":2}');
    });

    test('初始导航带上 headers(Referer / Cookie 不再丢)', () {
      final nav = WebViewNavigation.of(headers: {
        'Referer': 'https://example.com/',
        'Cookie': 'sid=abc',
        'X-Empty': '',
      });
      expect(nav.headers, {
        'Referer': 'https://example.com/',
        'Cookie': 'sid=abc',
      });
      expect(nav.toUrlRequest('https://example.com/x').headers, nav.headers);
    });

    test('UA 交给 InAppWebViewSettings,不重复进导航头', () {
      final nav = WebViewNavigation.of(headers: const {
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://example.com/',
      });
      expect(nav.headers.containsKey('User-Agent'), isFalse);
      expect(nav.headers['Referer'], 'https://example.com/');
    });

    test('没有 header 时不塞空 map(保持插件默认行为)', () {
      expect(WebViewNavigation.of().toUrlRequest('https://a/').headers, isNull);
    });

    test('WebView 传输不支持的方法明确抛错', () {
      expect(
        () => WebViewNavigation.of(method: 'PUT'),
        throwsA(isA<WebViewTransportException>()),
      );
      expect(
        () => WebViewNavigation.of(method: 'DELETE', body: '{}'),
        throwsA(isA<WebViewTransportException>()),
      );
    });

    test('GET 带 body 是矛盾组合,抛错而不是丢掉 body', () {
      expect(
        () => WebViewNavigation.of(method: 'GET', body: 'a=1'),
        throwsA(isA<WebViewTransportException>()),
      );
    });

    test('空方法按 GET 处理', () {
      expect(WebViewNavigation.of(method: '   ').method, 'GET');
    });
  });

  group('WebViewHttpService', () {
    test('不支持的方法在发车前就抛错,不会静默拿回首页', () async {
      await expectLater(
        WebViewHttpService().fetch(
          const HostRequest('https://example.com/api', method: 'PUT'),
        ),
        throwsA(isA<WebViewTransportException>()),
      );
    });

    test('GET 带 body 同样抛错', () async {
      await expectLater(
        WebViewHttpService().fetch(
          const HostRequest('https://example.com/api', body: 'a=1'),
        ),
        throwsA(isA<WebViewTransportException>()),
      );
    });
  });
}
