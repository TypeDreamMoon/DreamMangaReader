/// Dart SDK 自测 —— 不需要启服务，也不需要 pub get。
///
///   dart run test/run_tests.dart
///
/// 用假网络层把 SDK 自己的逻辑单独拎出来测，和 C++ 版 `tests/test_client.cpp`
/// 测的是同一批行为（方法名和错误语义必须一致）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/hertz_sdk.dart';

int _checks = 0;
int _fails = 0;

void check(bool ok, String what) {
  _checks++;
  if (ok) {
    print('  ok   $what');
  } else {
    print('  FAIL $what');
    _fails++;
  }
}

// ── 假网络层 ──────────────────────────────────────────────

class FakeTransport implements HertzTransport {
  FakeTransport(this.script);

  final List<FutureOr<HertzResponse> Function(HertzRequest)> script;
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

HertzResponse okJson(String dataJson, [Map<String, String> headers = const {}]) =>
    resp(200, body: '{"code":0,"msg":"ok","data":$dataJson}', headers: headers);

HertzClient makeClient(
  FakeTransport t, {
  int retries = 2,
  String token = 'static-token',
  FutureOr<String?> Function()? provider,
  void Function(RetryInfo info)? onRetry,
}) =>
    HertzClient(HertzClientOptions(
      baseUrl: 'http://test.local',
      appId: 'test-app',
      token: token,
      maxRetries: retries,
      transport: t,
      tokenProvider: provider,
      onRetry: onRetry,
    ));

// ── 测试 ──────────────────────────────────────────────────

Future<void> testErrorMapping() async {
  print('\n[错误映射]');
  {
    final t = FakeTransport([(_) => resp(404, body: '{"msg":"没有这条数据"}')]);
    final c = makeClient(t);
    try {
      await c.load('nope');
      check(false, '404 应该抛异常');
    } on HertzException catch (e) {
      check(e.isNotFound && e.status == 404, '404 → isNotFound');
      check(e.message == '没有这条数据', '错误信息来自服务端');
    }
  }
  {
    final t = FakeTransport([(_) => resp(409, body: '{"msg":"冲突"}')]);
    final c = makeClient(t);
    try {
      await c.save('k', utf8.encode('v'),
          const SaveOptions(ifMatch: 'stale'));
      check(false, '409 应该抛异常');
    } on HertzException catch (e) {
      check(e.isConflict, '409 → isConflict');
    }
  }
  {
    final t = FakeTransport([(_) => resp(413, body: '{}')]);
    final c = makeClient(t);
    try {
      await c.save('k', utf8.encode('v'));
      check(false, '413 应该抛异常');
    } on HertzException catch (e) {
      check(e.isTooLarge, '413 → isTooLarge');
    }
  }
  {
    final t = FakeTransport([(_) => throw StateError('连不上')]);
    final c = makeClient(t);
    try {
      await c.load('x');
      check(false, '网络错误应该抛异常');
    } on HertzException catch (e) {
      check(e.isNetwork && e.status == 0, '网络错误 → isNetwork 且 status=0');
    }
  }
}

Future<void> testRetry() async {
  print('\n[重试策略]');
  {
    var calls = 0;
    final t = FakeTransport([
      (_) {
        calls++;
        return resp(503, body: '{}');
      },
      (_) {
        calls++;
        return okJson('{"version":"v3","bytes":2,"updated_at":""}');
      },
    ]);
    final c = makeClient(t);
    final m = await c.save('k', utf8.encode('hi'));
    check(m.version == 'v3', '5xx 重试后成功');
    check(calls == 2, '恰好请求 2 次');
  }
  {
    var calls = 0;
    final t = FakeTransport([
      (_) {
        calls++;
        return resp(400, body: '{"msg":"参数错"}');
      }
    ]);
    final c = makeClient(t);
    try {
      await c.load('x');
    } catch (_) {}
    check(calls == 1, '4xx 不重试（重试也救不回来）');
  }
  {
    final infos = <RetryInfo>[];
    final t = FakeTransport([
      (_) => resp(429, body: '{"msg":"限流"}', headers: {'retry-after': '1'}),
      (_) => okJson('{"version":"v"}'),
    ]);
    final c = makeClient(t, onRetry: infos.add);
    await c.save('k', utf8.encode('v'));
    check(infos.length == 1, 'onRetry 被调用了一次');
    check(infos.isNotEmpty && infos[0].status == 429, '重试原因是 429');
    check(infos.isNotEmpty && infos[0].delayMs == 1000,
        '照 Retry-After 说的等 1 秒，不自己猜');
  }
  {
    var calls = 0;
    final t = FakeTransport([
      (_) {
        calls++;
        return resp(408, body: '{"msg":"服务端等超时了"}');
      },
      (_) {
        calls++;
        return okJson('{"version":"v"}');
      },
    ]);
    final c = makeClient(t);
    await c.load('k');
    check(calls == 2, '408 会重试（Azure 也是这么定的）');
  }
  {
    final infos = <RetryInfo>[];
    final t = FakeTransport([
      (_) => throw StateError('连不上'),
      (_) => okJson('{"version":"v"}'),
    ]);
    final c = makeClient(t, onRetry: infos.add);
    await c.save('k', utf8.encode('v'));
    check(infos.isNotEmpty && infos[0].delayMs > 0,
        '网络错误也要报出真实等待时间');
  }
}

Future<void> testTokenRefresh() async {
  print('\n[token 续期]');
  {
    var tokenCalls = 0;
    final t = FakeTransport([
      (_) => resp(401, body: '{}'),
      (_) => okJson('{"version":"v2"}'),
    ]);
    final c = makeClient(
      t,
      token: '',
      provider: () async {
        tokenCalls++;
        return 'tok$tokenCalls';
      },
    );
    final m = await c.save('k', utf8.encode('v'));
    check(m.version == 'v2', '401 后续期并成功');
    check(tokenCalls == 2, '取一次 + 刷新一次');
  }
  {
    var tokenCalls = 0;
    final t = FakeTransport([
      (_) => okJson('{"version":"v1"}'),
      (_) => okJson('{"version":"v2"}'),
    ]);
    final c = makeClient(
      t,
      token: '',
      provider: () async {
        tokenCalls++;
        return tokenCalls == 1 ? '' : 'tok';
      },
    );
    await c.save('a', utf8.encode('1'));
    await c.save('b', utf8.encode('2'));
    check(tokenCalls == 2, '空 token 不会被钉住（provider 被问了两次）');
    check(t.calls[0].headers.containsKey('Authorization') == false,
        '第一次没有 Authorization');
    check(t.calls[1].headers['Authorization'] == 'Bearer tok',
        'token 到位后立刻用上了');
  }
}

Future<void> testRequestShape() async {
  print('\n[请求形态]');
  final t = FakeTransport([(_) => okJson('{"version":"v"}')]);
  final c = makeClient(t);
  await c.save(
    'save:slot1',
    utf8.encode('{}'),
    const SaveOptions(
      permRead: PermRead.public,
      permWrite: PermWrite.server,
      ifMatch: 'abc',
      contentType: 'application/json',
    ),
  );

  final req = t.calls[0];
  check(req.method == 'PUT', '方法是 PUT');
  check(req.headers['X-Perm-Read'] == '2', 'X-Perm-Read 传对了');
  check(req.headers['X-Perm-Write'] == '0', 'X-Perm-Write 传对了');
  check(req.headers['If-Match'] == 'abc', 'If-Match 传对了');
  check(req.headers['Authorization'] == 'Bearer static-token',
      'Authorization 带上了');
  check(req.url.contains('save%3Aslot1'),
      'key 里的冒号被编码了（不会被当成路径分隔）: ${req.url}');
}

Future<void> testPagination() async {
  print('\n[分页]');
  final t = FakeTransport([
    (_) => okJson(
        '{"items":[{"key":"a","bytes":1,"version":"1"}],"next_after":"a"}'),
    (_) => okJson(
        '{"items":[{"key":"b","bytes":1,"version":"1"}],"next_after":""}'),
  ]);
  final c = makeClient(t);
  final keys = <String>[];
  await for (final m in c.list(const ListOptions(pageSize: 1))) {
    keys.add(m.key);
  }
  check(keys.join(',') == 'a,b', '两页都拿到了且顺序正确');
  check(t.calls.length == 2, '翻了两次页');
}

void testSha256() {
  print('\n[内容哈希]');
  const vectors = <int, String>{
    0: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    55: '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
    56: 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
    64: 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
    65: '635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0',
  };
  vectors.forEach((len, want) {
    final got = sha256Hex(List<int>.filled(len, 0x61)); // 'a'
    check(got == want, '$len 字节的 SHA-256');
  });
  check(
    sha256Hex(utf8.encode('abc')) ==
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'abc 的 SHA-256',
  );
}

Future<void> testConflictIdempotent() async {
  print('\n[409 幂等确认]');
  final payload = utf8.encode('hello');
  final hash = sha256Hex(payload);

  {
    final t = FakeTransport([
      (_) => resp(409, body: '{"code":409,"msg":"版本对不上"}'),
      (_) => resp(
            200,
            body: 'hello',
            headers: {'x-version': hash, 'x-perm-read': '1', 'x-perm-write': '1'},
          ),
    ]);
    final c = makeClient(t);
    final m = await c.save('save:slot1', payload,
        const SaveOptions(ifMatch: 'stale-version'));
    check(m.version == hash, '服务端就是自己刚写的那份 → 按成功返回');
    check(t.calls.length == 2, '只补了一次 GET，没有反复重试');
  }

  {
    final t = FakeTransport([
      (_) => resp(409, body: '{"code":409,"msg":"真的冲突"}'),
      (_) => resp(200, body: 'other', headers: {'x-version': 'someone-else'}),
    ]);
    final c = makeClient(t);
    var threw = false;
    try {
      await c.save('save:slot1', payload,
          const SaveOptions(ifMatch: 'stale-version'));
    } on HertzException catch (e) {
      threw = e.isConflict;
    }
    check(threw, '内容不一样 → 仍然是真冲突，不能被吞成成功');
  }

  {
    final t = FakeTransport([
      (_) => resp(409, body: '{"code":409,"msg":"已存在"}'),
    ]);
    final c = makeClient(t);
    var threw = false;
    try {
      await c.save('save:slot1', payload, const SaveOptions(ifMatch: '*'));
    } on HertzException catch (e) {
      threw = e.isConflict;
    }
    // If-Match:* 是「只更新」：服务端不会因为别人写过而回 409，真回了也不是「自己刚写成」
    check(threw, 'If-Match:* 的 409 不补偿');
    check(t.calls.length == 1, '也没有多打一次 GET');
  }
}

Future<void> testCreateOnly() async {
  print('\n[只创建 createOnly]');
  final payload = utf8.encode('first');
  final hash = sha256Hex(payload);
  {
    final t = FakeTransport([(_) => okJson('{"version":"$hash"}')]);
    final c = makeClient(t);
    await c.save('save:all', payload, const SaveOptions(createOnly: true));
    final h = t.calls.single.headers;
    check(h['If-None-Match'] == '*', 'createOnly → If-None-Match: *');
    check(!h.containsKey('If-Match'),
        'createOnly 不带 If-Match（"*" 在服务端是「只更新」）');
  }
  {
    final t = FakeTransport([(_) => okJson('{}')]);
    final c = makeClient(t);
    var threw = false;
    try {
      await c.save(
          'k', payload, const SaveOptions(createOnly: true, ifMatch: 'v1'));
    } on ArgumentError {
      threw = true;
    }
    check(threw && t.calls.isEmpty, 'createOnly + ifMatch → 本地就拒绝，不打网络');
  }
  {
    final t = FakeTransport([
      (_) => resp(409, body: '{"code":7001,"msg":"已存在"}'),
      (_) => resp(200, body: 'first', headers: {'x-version': hash}),
    ]);
    final c = makeClient(t);
    final m = await c.save('k', payload, const SaveOptions(createOnly: true));
    check(m.version == hash && t.calls.length == 2,
        'createOnly 的 409 若服务端就是这份内容 → 按成功返回（响应丢了后的重试）');
  }
  {
    final t = FakeTransport([
      (_) => resp(409, body: '{"code":7001,"msg":"已存在"}'),
      (_) => resp(200, body: 'other', headers: {'x-version': 'someone-else'}),
    ]);
    final c = makeClient(t);
    var conflict = false;
    try {
      await c.save('k', payload, const SaveOptions(createOnly: true));
    } on HertzException catch (e) {
      conflict = e.isConflict && e.code == HertzErrorCode.versionConflict;
    }
    check(conflict, 'createOnly 撞上别人建好的记录 → 真冲突');
  }
}

Future<void> testPreconditionFailed() async {
  print('\n[412 记录不存在]');
  var calls = 0;
  final t = FakeTransport([
    (_) {
      calls++;
      return resp(412,
          body: '{"code":7002,"msg":"precondition failed, no matching record exists"}');
    },
  ]);
  final c = makeClient(t);
  try {
    await c.save('k', utf8.encode('v'), const SaveOptions(ifMatch: 'v-gone'));
    check(false, '412 应该抛异常');
  } on HertzException catch (e) {
    check(e.isPreconditionFailed && e.status == 412, '412 → isPreconditionFailed');
    check(e.code == HertzErrorCode.preconditionFailed, '业务码 7002');
    check(!e.isConflict, '412 不是 409（没有当前版本可比）');
  }
  check(calls == 1, '412 不重试');
}

Future<void> testErrorCodeSources() async {
  print('\n[业务码来源]');
  {
    // HEAD 的错误响应只有头（X-Error-Code），没有 body
    final t = FakeTransport([
      (_) => HertzResponse(
            status: 404,
            headers: {'x-error-code': '1004'},
            body: Uint8List(0),
          ),
    ]);
    final c = makeClient(t);
    try {
      await c.loadMeta('k');
      check(false, 'HEAD 404 应该抛异常');
    } on HertzException catch (e) {
      check(e.isNotFound && e.code == HertzErrorCode.notFound,
          'HEAD 404 的业务码取自 X-Error-Code');
    }
  }
  {
    final t = FakeTransport([(_) => resp(404, body: '404 page not found')]);
    final c = makeClient(t);
    try {
      await c.load('k');
      check(false, '404 应该抛异常');
    } on HertzException catch (e) {
      check(e.isNotFound && e.code == 0,
          '别的服务回的 404（非信封、无 X-Error-Code）→ code 0，调用方能分辨');
    }
  }
  {
    final t = FakeTransport([
      (_) => resp(200,
          body: '{"code":0,"msg":"ok","data":{}}',
          headers: {'x-version': 'from-header'}),
    ]);
    final c = makeClient(t);
    final m = await c.save('k', utf8.encode('v'));
    check(m.version == 'from-header', '信封里没有 version → 退回 X-Version 头');
  }
}

/// 起一个只活在本测试里的回环 HTTP 服务（不需要外部服务）。
Future<HttpServer> _loopback(void Function(HttpRequest req) handle) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handle);
  return server;
}

Future<void> testIoTransport() async {
  print('\n[IoTransport 真网络（回环）]');
  {
    final seen = <String, String>{};
    var received = 0;
    final server = await _loopback((req) async {
      seen['content-length'] = req.headers.value('content-length') ?? '';
      seen['transfer-encoding'] = req.headers.value('transfer-encoding') ?? '';
      received =
          (await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b))).length;
      req.response
        ..statusCode = 200
        ..write('{"code":0,"msg":"ok","data":{}}');
      await req.response.close();
    });
    try {
      final payload = Uint8List.fromList(List<int>.filled(100000, 0x61));
      final res = await IoTransport().send(HertzRequest(
        method: 'PUT',
        url: 'http://127.0.0.1:${server.port}/api/v1/data/a/k',
        timeoutMs: 5000,
        body: payload,
      ));
      check(res.status == 200, 'PUT 往返成功');
      check(seen['content-length'] == '100000',
          'PUT 带了 Content-Length（${seen['content-length']}）');
      check(seen['transfer-encoding']!.isEmpty,
          '没有走 chunked（appdata 会对 chunked 回 400）');
      check(received == 100000, '服务端收全了请求体');

      await IoTransport().send(HertzRequest(
        method: 'PUT',
        url: 'http://127.0.0.1:${server.port}/api/v1/data/a/k',
        timeoutMs: 5000,
      ));
      check(seen['content-length'] == '0', '空 PUT 也声明 Content-Length: 0');
    } finally {
      await server.close(force: true);
    }
  }
  {
    // 头发完、body 发一半就不动了：没有 body 超时的话 send() 会永远挂着。
    // 用裸 socket 当服务端：这样才看得见「客户端有没有把连接掐掉」。
    final closed = Completer<void>();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((sock) {
      var sent = false;
      sock.listen((_) {
        if (sent) return;
        sent = true;
        sock.add(utf8.encode('HTTP/1.1 200 OK\r\n'
            'Content-Length: 1000\r\n'
            '\r\n'
            'only-ten-b'));
      }, onDone: () {
        if (!closed.isCompleted) closed.complete();
        sock.destroy();
      }, onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      });
    });
    final sw = Stopwatch()..start();
    var timedOut = false;
    try {
      await IoTransport().send(HertzRequest(
        method: 'GET',
        url: 'http://127.0.0.1:${server.port}/stall',
        timeoutMs: 300,
      ));
    } on TimeoutException {
      timedOut = true;
    } finally {
      sw.stop();
    }
    check(timedOut, '响应体卡住 → TimeoutException（${sw.elapsedMilliseconds}ms）');
    check(sw.elapsedMilliseconds < 3000, '没有一直挂着');
    final aborted = await closed.future
        .then((_) => true)
        .timeout(const Duration(seconds: 3), onTimeout: () => false);
    check(aborted, '超时后连接被掐掉了（服务端看到断开）');
    await server.close();
  }
}

Future<void> testErrorCode() async {
  print('\n[业务错误码]');
  {
    final t = FakeTransport([
      (_) => resp(409, body: '{"code":409,"msg":"版本对不上"}'),
    ]);
    final c = makeClient(t);
    try {
      await c.load('k');
      check(false, '409 应该抛异常');
    } on HertzException catch (e) {
      check(e.code == 409, 'HertzException.code 拿到了服务端的 code');
      check(e.status == 409, 'status 仍然是 HTTP 状态码');
      check(e.message == '版本对不上', 'message 仍然是服务端的 msg');
    }
  }
  {
    final t = FakeTransport([(_) => resp(404, body: 'not json')]);
    final c = makeClient(t);
    try {
      await c.load('k');
    } on HertzException catch (e) {
      check(e.code == 0, '非信封响应 → code 为 0');
    }
  }
}

Future<void> testLoadMeta() async {
  print('\n[只取元信息 HEAD]');
  final t = FakeTransport([
    (_) => HertzResponse(
          status: 200,
          headers: {
            'x-version': 'abc123',
            'x-bytes': '1638400',
            'x-perm-read': '1',
            'x-perm-write': '0',
            'x-updated-at': '2026-10-24T02:00:00Z',
            'content-type': 'application/gzip',
          },
          body: Uint8List(0),
        ),
  ]);
  final c = makeClient(t);
  final m = await c.loadMeta('save:slot1');

  check(t.calls.length == 1 && t.calls[0].method == 'HEAD', '用的是 HEAD');
  check(m.version == 'abc123', '拿到 version');
  check(m.bytes == 1638400, '字节数来自 X-Bytes，不是 body 长度');
  check(m.permWrite == 0, '拿到权限位');
  check(m.contentType == 'application/gzip', '拿到 content-type');
}

Future<void> testLoadIfChanged() async {
  print('\n[条件 GET]');
  {
    final t = FakeTransport([
      (_) => resp(304, headers: {'x-version': 'v-known'}),
    ]);
    final c = makeClient(t);
    final r = await c.loadIfChanged('save:slot1', 'v-known');
    check(r.notModified, '304 → notModified，不抛异常');
    check(t.calls[0].method == 'GET', '用的是 GET');
    check(t.calls[0].headers['If-None-Match'] == '"v-known"',
        'If-None-Match 按 RFC 带了引号');
  }
  {
    final t = FakeTransport([
      (_) => resp(200,
          body: 'new',
          headers: {'x-version': 'v-new', 'x-perm-read': '1', 'x-perm-write': '1'}),
    ]);
    final c = makeClient(t);
    final r = await c.loadIfChanged('save:slot1', 'v-old');
    check(r.notModified == false, '200 → 有新内容');
    check(r.doc!.version == 'v-new' && r.doc!.data.length == 3, '新内容拿到了');
  }
  {
    final t = FakeTransport([(_) => resp(200, body: 'x')]);
    final c = makeClient(t);
    await c.loadIfChanged('k', '');
    check(t.calls[0].headers.containsKey('If-None-Match') == false,
        '不知道版本就不带条件头');
  }
}

Future<void> main() async {
  print('=== Hertz Dart SDK 测试 ===');
  await testErrorMapping();
  await testRetry();
  await testTokenRefresh();
  await testRequestShape();
  await testPagination();
  testSha256();
  await testConflictIdempotent();
  await testErrorCode();
  await testLoadMeta();
  await testLoadIfChanged();
  await testCreateOnly();
  await testPreconditionFailed();
  await testErrorCodeSources();
  await testIoTransport();

  print('\n----------------------------------------');
  print('共 $_checks 项，失败 $_fails 项');
  print(_fails == 0 ? 'RESULT: 全部通过' : 'RESULT: 有失败');
  // 脚本 / CI 靠退出码判断，光打印「有失败」会被当成通过
  if (_fails > 0) exitCode = 1;
}
