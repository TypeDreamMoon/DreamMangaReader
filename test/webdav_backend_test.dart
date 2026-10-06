import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/sync/sync_backend.dart';
import 'package:dream_manga_reader/core/sync/webdav_backend.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call {
  _Call(this.method, this.headers, this.body);
  final String method;
  final Map<String, dynamic> headers;
  final Object? body;

  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return '${entry.value}';
    }
    return null;
  }
}

/// 脚本化的应答队列 + 请求记录。用完队列后一直返回最后一条。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.replies);

  final List<ResponseBody Function()> replies;
  final List<_Call> calls = [];
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(_Call(
      options.method,
      Map<String, dynamic>.from(options.headers),
      options.data,
    ));
    final reply = replies[_index.clamp(0, replies.length - 1)];
    _index++;
    return reply();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _reply(
  String body,
  int status, {
  String? etag,
}) =>
    ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: ['application/json'],
      if (etag != null) 'etag': [etag],
    });

void main() {
  WebDavBackend backendWith(_StubAdapter adapter) => WebDavBackend(
        baseUrl: 'https://dav.example.com/dmr',
        username: 'alice',
        password: 's3cret',
        adapter: adapter,
      );

  // 之前 push 是无条件覆盖:两台设备同时同步,后写的一方把先写的整份抹掉,
  // 用户看到的是「刚在另一台加的收藏又没了」。
  test('pull 记下 ETag,push 带 If-Match 推上去', () async {
    final adapter = _StubAdapter([
      () => _reply('{"v":1}', 200, etag: '"v1"'), // GET
      () => _reply('', 201), // MKCOL
      () => _reply('', 204, etag: '"v2"'), // PUT
    ]);
    final backend = backendWith(adapter);

    expect(await backend.pull(), {'v': 1});
    await backend.push({'v': 2});

    final put = adapter.calls.last;
    expect(put.method, 'PUT');
    expect(put.header('If-Match'), '"v1"');
  });

  test('412 变成 SyncConflict,并带上服务器最新那份', () async {
    final adapter = _StubAdapter([
      () => _reply('{"v":1}', 200, etag: '"v1"'), // GET
      () => _reply('', 201), // MKCOL
      () => _reply('', 412), // PUT 撞车
      () => _reply('{"v":9}', 200, etag: '"v9"'), // 冲突后重新 GET
    ]);
    final backend = backendWith(adapter);
    await backend.pull();

    await expectLater(
      backend.push({'v': 2}),
      throwsA(isA<SyncConflict>().having((e) => e.remote, 'remote', {'v': 9})),
    );
  });

  test('冲突重试用的是新版本号,不会 412 到死', () async {
    final adapter = _StubAdapter([
      () => _reply('{"v":1}', 200, etag: '"v1"'), // GET
      () => _reply('', 201), // MKCOL
      () => _reply('', 412), // PUT 撞车
      () => _reply('{"v":9}', 200, etag: '"v9"'), // 冲突后重新 GET
      () => _reply('', 201), // MKCOL(重试)
      () => _reply('', 204, etag: '"v10"'), // PUT 重试
    ]);
    final backend = backendWith(adapter);
    await backend.pull();
    await expectLater(backend.push({'v': 2}), throwsA(isA<SyncConflict>()));

    await backend.push({'v': 10});

    expect(adapter.calls.last.header('If-Match'), '"v9"');
  });

  test('远端还没有文件时不带 If-Match', () async {
    final adapter = _StubAdapter([
      () => _reply('', 404), // GET
      () => _reply('', 201), // MKCOL
      () => _reply('', 201, etag: '"v1"'), // PUT
    ]);
    final backend = backendWith(adapter);

    expect(await backend.pull(), isNull);
    await backend.push({'v': 1});

    expect(adapter.calls.last.header('If-Match'), isNull);
  });

  test('弱 ETag 不当条件用(If-Match 不接受弱验证器)', () async {
    final adapter = _StubAdapter([
      () => _reply('{"v":1}', 200, etag: 'W/"weak"'),
      () => _reply('', 201),
      () => _reply('', 204),
    ]);
    final backend = backendWith(adapter);

    await backend.pull();
    await backend.push({'v': 2});

    expect(adapter.calls.last.header('If-Match'), isNull);
  });

  test('服务器 PUT 不回 ETag → 下次不拿旧版本号硬顶', () async {
    final adapter = _StubAdapter([
      () => _reply('{"v":1}', 200, etag: '"v1"'), // GET
      () => _reply('', 201), // MKCOL
      () => _reply('', 204), // PUT,没有 ETag
      () => _reply('', 201), // MKCOL
      () => _reply('', 204), // PUT
    ]);
    final backend = backendWith(adapter);
    await backend.pull();
    await backend.push({'v': 2});

    await backend.push({'v': 3});

    expect(adapter.calls.last.header('If-Match'), isNull);
  });

  test('上传失败仍然报错', () async {
    final adapter = _StubAdapter([
      () => _reply('', 404),
      () => _reply('', 201),
      () => _reply('', 409),
    ]);
    final backend = backendWith(adapter);
    await backend.pull();

    await expectLater(backend.push({'v': 1}), throwsA(isA<Exception>()));
  });
}
