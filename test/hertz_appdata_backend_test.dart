import 'dart:convert';
import 'dart:typed_data';

import 'package:dream_manga_reader/core/net/iam_auth.dart';
import 'package:dream_manga_reader/core/sync/hertz_appdata_backend.dart';
import 'package:dream_manga_reader/core/sync/sync_backend.dart';
import 'package:dream_manga_reader/core/sync/sync_messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hertz_sdk/hertz_sdk.dart';

/// 假网络层：按剧本返回响应，并记下每次请求。
class FakeTransport implements HertzTransport {
  FakeTransport(this.script);

  final List<HertzResponse Function(HertzRequest)> script;
  final List<HertzRequest> calls = [];
  var _next = 0;

  @override
  Future<HertzResponse> send(HertzRequest req) async {
    calls.add(req);
    final idx = _next < script.length ? _next : script.length - 1;
    _next++;
    return script[idx](req);
  }
}

HertzResponse resp(
  int status, {
  String body = '',
  Map<String, String> headers = const {},
}) =>
    HertzResponse(
      status: status,
      headers: headers,
      body: Uint8List.fromList(utf8.encode(body)),
    );

HertzResponse okData(String dataJson, [Map<String, String> headers = const {}]) =>
    resp(200, body: '{"code":0,"msg":"ok","data":$dataJson}', headers: headers);

HertzAppDataBackend backend(FakeTransport t) => HertzAppDataBackend(
      baseUrl: 'http://test.local/',
      auth: IamAuth(),
      transport: t,
      tokenSource: () async => 'tok',
    );

void main() {
  test('pull 首次同步（404）返回 null', () async {
    final t = FakeTransport([
      (_) => resp(404, body: '{"code":404,"msg":"没有这条数据"}'),
    ]);
    expect(await backend(t).pull(), isNull);
    expect(t.calls.single.method, 'GET');
    expect(
      t.calls.single.url,
      'http://test.local/api/v1/data/dream_manga_reader/save%3Aall',
    );
  });

  test('pull 拿到 blob，push 带上读到的版本', () async {
    final t = FakeTransport([
      (_) => resp(200,
          body: '{"library":{"favorites":[1,2]}}',
          headers: {'x-version': 'v1'}),
      (_) => okData('{"version":"v2"}'),
    ]);
    final b = backend(t);

    final blob = await b.pull();
    expect(blob, {
      'library': {
        'favorites': [1, 2]
      }
    });

    await b.push({'library': <String, dynamic>{}});
    expect(t.calls[1].method, 'PUT');
    expect(t.calls[1].headers['If-Match'], 'v1');
  });

  test('第一次 push 不带 If-Match', () async {
    final t = FakeTransport([(_) => okData('{"version":"v1"}')]);
    await backend(t).push({'a': 1});

    expect(t.calls.single.method, 'PUT');
    expect(t.calls.single.headers.containsKey('If-Match'), isFalse);
    expect(t.calls.single.headers['Content-Type'], 'application/json');
  });

  test('push 409 抛 SyncConflict，并把远端当前态带回去', () async {
    final t = FakeTransport([
      (_) => resp(409, body: '{"code":409,"msg":"冲突"}'),
      (_) => resp(200,
          body: '{"library":{"favorites":[9]}}',
          headers: {'x-version': 'vX'}),
    ]);
    final b = backend(t);

    try {
      await b.push({'library': <String, dynamic>{}});
      fail('应该抛 SyncConflict');
    } on SyncConflict catch (e) {
      expect(e.remote, {
        'library': {
          'favorites': [9]
        }
      });
    }
    // 409 之后补了一次 GET：把远端当前态取回来给上层重合并
    expect(t.calls.length, 2);
  });

  test('push 401 → sessionExpired', () async {
    final t = FakeTransport([(_) => resp(401, body: '{}')]);
    try {
      await backend(t).push(<String, dynamic>{});
      fail('应该抛 SyncException');
    } on SyncException catch (e) {
      expect(e.notice.message, SyncMessage.sessionExpired);
    }
  });

  test('push 413 → pushFailed，带 413', () async {
    final t = FakeTransport([(_) => resp(413, body: '{}')]);
    try {
      await backend(t).push(<String, dynamic>{});
      fail('应该抛 SyncException');
    } on SyncException catch (e) {
      expect(e.notice.message, SyncMessage.pushFailed);
      expect(e.notice.httpStatus, 413);
    }
  });

  test('test() 未登录直接返回，不打网络', () async {
    final t = FakeTransport([(_) => okData('{}')]);
    final r = await backend(t).test();

    expect(r.ok, isFalse);
    expect(r.notice.message, SyncMessage.serviceOnlineNotLoggedIn);
    expect(t.calls, isEmpty);
  });
}
