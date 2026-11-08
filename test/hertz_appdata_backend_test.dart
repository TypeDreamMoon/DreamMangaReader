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

/// appdata 自己的「没有这条记录」：信封 + X-Error-Code（和服务端 writeEnvelope 一致）。
HertzResponse appdataNotFound() => resp(404,
    body: '{"code":1004,"msg":"not found","trace_id":"t"}',
    headers: {'x-error-code': '1004'});

/// GET 一条已存在的记录。
HertzResponse record(String body, String version) =>
    resp(200, body: body, headers: {'x-version': version});

HertzAppDataBackend backend(FakeTransport t, {IamAuth? auth}) =>
    HertzAppDataBackend(
      baseUrl: 'http://test.local/',
      auth: auth ?? IamAuth(),
      transport: t,
      tokenSource: () async => 'tok',
    );

Future<SyncException> expectSyncException(Future<void> Function() body) async {
  try {
    await body();
  } on SyncException catch (e) {
    return e;
  }
  fail('应该抛 SyncException');
}

void main() {
  group('pull', () {
    test('appdata 的 404（code 1004）= 首次同步，返回 null', () async {
      final t = FakeTransport([(_) => appdataNotFound()]);
      expect(await backend(t).pull(), isNull);
      expect(t.calls.single.method, 'GET');
      expect(
        t.calls.single.url,
        'http://test.local/api/v1/data/dream_manga_reader/save%3Aall',
      );
    });

    test('不是 appdata 回的 404（地址配错）→ pullFailed，绝不当成「没数据」', () async {
      for (final r in [
        resp(404, body: '404 page not found'),
        resp(404, body: '<html><body>Not Found</body></html>'),
        // 旧 dreamreader-sync 风格的信封：code 是 404，不是 appdata 的 1004
        resp(404, body: '{"code":404,"msg":"没有这条数据"}'),
      ]) {
        final t = FakeTransport([(_) => r]);
        final e = await expectSyncException(() => backend(t).pull());
        expect(e.notice.message, SyncMessage.pullFailed);
        expect(e.notice.httpStatus, 404);
      }
    });

    test('记录存在但内容坏了 → pullFailed，不当成「没数据」', () async {
      for (final r in [
        record('', 'v1'), // 空 body
        record('[1,2,3]', 'v1'), // 不是对象
        record('"str"', 'v1'),
        record('{not json', 'v1'),
        resp(200, body: '{"a":1}'), // 没有 X-Version
      ]) {
        final t = FakeTransport([(_) => r]);
        final e = await expectSyncException(() => backend(t).pull());
        expect(e.notice.message, SyncMessage.pullFailed, reason: r.bodyText);
      }
    });

    test('401 → sessionExpired', () async {
      final t = FakeTransport([(_) => resp(401, body: '{}')]);
      final e = await expectSyncException(() => backend(t).pull());
      expect(e.notice.message, SyncMessage.sessionExpired);
    });
  });

  group('push', () {
    test('pull 拿到 blob，push 带上读到的版本（不带 If-None-Match）', () async {
      final t = FakeTransport([
        (_) => record('{"library":{"favorites":[1,2]}}', 'v1'),
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
      expect(t.calls[1].headers.containsKey('If-None-Match'), isFalse);
    });

    test('首推（云端没有）只创建：If-None-Match: *，不带 If-Match', () async {
      final t = FakeTransport([
        (_) => appdataNotFound(),
        (_) => okData('{"version":"v1"}'),
      ]);
      final b = backend(t);
      expect(await b.pull(), isNull);
      await b.push({'a': 1});

      final put = t.calls[1];
      expect(put.method, 'PUT');
      expect(put.headers['If-None-Match'], '*');
      // `If-Match: *` 在服务端是「只更新」，首推用它会 412
      expect(put.headers.containsKey('If-Match'), isFalse);
      expect(put.headers['Content-Type'], 'application/json');
    });

    test('没 pull 过直接 push 也是只创建（不是无条件覆盖）', () async {
      final t = FakeTransport([(_) => okData('{"version":"v1"}')]);
      await backend(t).push({'a': 1});
      expect(t.calls.single.headers['If-None-Match'], '*');
    });

    test('成功后的下一次推送带上新版本', () async {
      final t = FakeTransport([
        (_) => okData('{"version":"v1"}'),
        (_) => okData('{"version":"v2"}'),
      ]);
      final b = backend(t);
      await b.push({'a': 1});
      await b.push({'a': 2});
      expect(t.calls[1].headers['If-Match'], 'v1');
      expect(t.calls[1].headers.containsKey('If-None-Match'), isFalse);
    });

    test('写入响应没有 version → pushFailed，不悄悄留空', () async {
      final t = FakeTransport([(_) => okData('{}')]);
      final e = await expectSyncException(() => backend(t).push({'a': 1}));
      expect(e.notice.message, SyncMessage.pushFailed);
    });

    test('push 409 抛 SyncConflict，并把远端当前态带回去', () async {
      final t = FakeTransport([
        (_) => resp(409, body: '{"code":7001,"msg":"冲突"}'),
        // SDK 先读一次比内容哈希（确认不是「自己刚写成、响应丢了」）
        (_) => record('{"library":{"favorites":[9]}}', 'vX'),
        // 后端再读一次，把远端当前态带给上层
        (_) => record('{"library":{"favorites":[9]}}', 'vX'),
        (_) => okData('{"version":"vY"}'),
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
      // 409 之后：SDK 的幂等确认 GET + 取远端当前态的 GET
      expect(t.calls.map((c) => c.method), ['PUT', 'GET', 'GET']);

      // 重合并后的再推带的是刚取回来的版本
      await b.push({'library': <String, dynamic>{}});
      expect(t.calls[3].headers['If-Match'], 'vX');
    });

    test('首推撞上别的设备先建好的记录（409）→ 重载 → 再推带版本', () async {
      final t = FakeTransport([
        (_) => resp(409, body: '{"code":7001,"msg":"已存在"}'),
        (_) => record('{"b":2}', 'vOther'), // SDK 幂等确认：内容不同 → 真冲突
        (_) => record('{"b":2}', 'vOther'), // 后端取远端当前态
        (_) => okData('{"version":"vMerged"}'),
      ]);
      final b = backend(t);
      try {
        await b.push({'a': 1});
        fail('应该抛 SyncConflict');
      } on SyncConflict catch (e) {
        expect(e.remote, {'b': 2});
      }
      expect(t.calls[0].headers['If-None-Match'], '*');
      await b.push({'a': 1, 'b': 2});
      expect(t.calls[3].headers['If-Match'], 'vOther');
      expect(t.calls[3].headers.containsKey('If-None-Match'), isFalse);
    });

    test('push 412（记录已被删）→ 重载拿到 404 → SyncConflict(null)，下一推只创建', () async {
      final t = FakeTransport([
        (_) => record('{"a":1}', 'v1'),
        (_) => resp(412,
            body: '{"code":7002,"msg":"precondition failed"}',
            headers: {'x-error-code': '7002'}),
        (_) => appdataNotFound(),
        (_) => okData('{"version":"v2"}'),
      ]);
      final b = backend(t);
      await b.pull();

      try {
        await b.push({'a': 2});
        fail('412 应该走 SyncConflict，而不是 pushFailed');
      } on SyncConflict catch (e) {
        expect(e.remote, isNull);
      }
      expect(t.calls[1].headers['If-Match'], 'v1');
      expect(t.calls[2].method, 'GET');

      await b.push({'a': 2});
      expect(t.calls[3].headers['If-None-Match'], '*');
      expect(t.calls[3].headers.containsKey('If-Match'), isFalse);
    });

    test('push 412 → 重载拿到别人新建的记录 → SyncConflict(remote)', () async {
      final t = FakeTransport([
        (_) => record('{"a":1}', 'v1'),
        (_) => resp(412, body: '{"code":7002,"msg":"precondition failed"}'),
        (_) => record('{"c":3}', 'v9'),
      ]);
      final b = backend(t);
      await b.pull();
      try {
        await b.push({'a': 2});
        fail('应该抛 SyncConflict');
      } on SyncConflict catch (e) {
        expect(e.remote, {'c': 3});
      }
    });

    test('冲突后的重载失败 → pushFailed，不能折成 SyncConflict(null)', () async {
      // SyncConflict(null) 在上层的意思是「服务端已清空」，会拿本地整份去覆盖
      for (final reload in [
        resp(500, body: '{"code":1,"msg":"internal error"}'),
        resp(404, body: '404 page not found'),
        record('[]', 'v2'),
      ]) {
        final t = FakeTransport([
          (_) => resp(409, body: '{"code":7001,"msg":"冲突"}'),
          (_) => reload, // SDK 幂等确认读不回来 → 按原冲突抛
          (_) => reload, // 后端取远端当前态也失败
        ]);
        Object? thrown;
        try {
          await backend(t).push({'a': 1});
        } catch (e) {
          thrown = e;
        }
        expect(thrown, isA<SyncException>(), reason: reload.bodyText);
        expect((thrown! as SyncException).notice.message, SyncMessage.pushFailed);
      }
    });

    test('push 401 → sessionExpired', () async {
      final t = FakeTransport([(_) => resp(401, body: '{}')]);
      final e = await expectSyncException(() => backend(t).push(<String, dynamic>{}));
      expect(e.notice.message, SyncMessage.sessionExpired);
    });

    test('push 413 → pushFailed，带 413', () async {
      final t = FakeTransport([(_) => resp(413, body: '{"code":7003}')]);
      final e = await expectSyncException(() => backend(t).push(<String, dynamic>{}));
      expect(e.notice.message, SyncMessage.pushFailed);
      expect(e.notice.httpStatus, 413);
    });
  });

  group('test()', () {
    test('未登录直接返回，不打网络', () async {
      final t = FakeTransport([(_) => okData('{}')]);
      final r = await backend(t).test();

      expect(r.ok, isFalse);
      expect(r.notice.message, SyncMessage.serviceOnlineNotLoggedIn);
      expect(t.calls, isEmpty);
    });

    IamAuth loggedIn() => IamAuth()
      ..debugSeedTokens(
        access: 'tok',
        refresh: 'refresh',
        expiresAtMs: DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
      );

    test('HEAD 404 带 appdata 业务码（X-Error-Code: 1004）→ 就绪（只是还没数据）', () async {
      // HEAD 没有 body，业务码只在响应头里
      final t = FakeTransport([
        (_) => HertzResponse(
              status: 404,
              headers: {'x-error-code': '1004'},
              body: Uint8List(0),
            ),
      ]);
      final r = await backend(t, auth: loggedIn()).test();
      expect(t.calls.single.method, 'HEAD');
      expect(r.ok, isTrue);
      expect(r.notice.message, SyncMessage.testAccountReady);
    });

    test('HEAD 404 没有 appdata 业务码（地址配错）→ 失败', () async {
      final t = FakeTransport([
        (_) => HertzResponse(status: 404, body: Uint8List(0)),
      ]);
      final r = await backend(t, auth: loggedIn()).test();
      expect(r.ok, isFalse);
      expect(r.notice.message, SyncMessage.unexpectedStatus);
      expect(r.notice.httpStatus, 404);
    });
  });
}
