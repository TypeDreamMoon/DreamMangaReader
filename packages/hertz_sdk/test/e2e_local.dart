/// 本地端到端验证：需要一个在跑的 appdata 服务（默认 http://127.0.0.1:8083，dev 模式）。
///
///   dart run test/e2e_local.dart
///   BASE=http://127.0.0.1:8083 dart run test/e2e_local.dart
///
/// 和 `run_tests.dart` 的分工：那个用假网络层测 SDK 自己的逻辑，这个走真 HTTP、
/// 真 Postgres，验的是服务端和 SDK 对同一份契约的理解一致。
library;

import 'dart:convert';
import 'dart:io';

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

Future<String> devToken(String base, String uid) async {
  final c = HttpClient();
  try {
    final req = await c.postUrl(Uri.parse('$base/dev/token'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'uid': uid}));
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    final m = jsonDecode(body) as Map<String, dynamic>;
    return (m['access_token'] as String?) ?? '';
  } finally {
    c.close(force: true);
  }
}

Future<void> main() async {
  final base = Platform.environment['BASE'] ?? 'http://127.0.0.1:8083';
  print('=== Hertz Dart SDK 端到端（$base）===');

  final token = await devToken(base, 'e2e-user');
  check(token.isNotEmpty, '从 /dev/token 拿到令牌');
  if (token.isEmpty) return;

  final client = HertzClient(HertzClientOptions(
    baseUrl: base,
    appId: 'dream_manga_reader',
    token: token,
    onRetry: (i) => print('    重试: $i'),
  ));

  const key = 'e2e:roundtrip';
  final payload = utf8.encode('{"library":{"favorites":[1,2,3]}}');

  // ── 写 ──
  final saved = await client.save(key, payload,
      const SaveOptions(contentType: 'application/json'));
  check(saved.version.isNotEmpty, 'save 返回 version');
  check(saved.version == sha256Hex(payload), 'version 就是内容 SHA-256');
  check(saved.bytes == payload.length, 'save 返回字节数');

  // ── 读 ──
  final doc = await client.load(key);
  check(listEquals(doc.data, payload), 'load 字节与写入完全一致');
  check(doc.version == saved.version, 'load 的 version 与 save 一致');
  check(doc.contentType == 'application/json', 'content-type 保留');

  // ── 元信息（HEAD）──
  final meta = await client.loadMeta(key);
  check(meta.version == saved.version, 'HEAD 拿到同样的 version');
  check(meta.bytes == payload.length, 'HEAD 拿到 X-Bytes');

  // ── 条件 GET ──
  final same = await client.loadIfChanged(key, saved.version);
  check(same.notModified, '版本没变 → 304，不传 body');

  final changed = await client.loadIfChanged(key, 'not-the-current-version');
  check(!changed.notModified && changed.doc != null, '版本对不上 → 200 + 内容');

  // ── 乐观锁 ──
  final payload2 = utf8.encode('{"library":{"favorites":[]}}');
  final saved2 = await client.save(key, payload2,
      SaveOptions(ifMatch: saved.version, contentType: 'application/json'));
  check(saved2.version != saved.version, '带正确 If-Match 写入成功，版本变了');

  var conflicted = false;
  try {
    await client.save(key, utf8.encode('{"library":{"favorites":[9]}}'),
        SaveOptions(ifMatch: saved.version, contentType: 'application/json'));
  } on HertzException catch (e) {
    conflicted = e.isConflict;
  }
  check(conflicted, '带过期 If-Match + 不同内容 → 409');

  // ── 列表 ──
  final keys = <String>[];
  await for (final m in client.list(const ListOptions(prefix: 'e2e:'))) {
    keys.add(m.key);
  }
  check(keys.contains(key), 'list(prefix) 能列出刚写的 key');

  // ── 公开摘要 ──
  // 注意：服务端 `/api/v1/public/*` 也挂了鉴权中间件，所以 perm_read=Public
  // 的语义是「**登录后**跨用户可读」，不是匿名可读。这两条都验一遍。
  const summaryKey = 'showcase';
  await client.publishSummary({'level': 42, 'chapter': 8}, key: summaryKey);

  final otherToken = await devToken(base, 'e2e-other');
  final other = HertzClient(HertzClientOptions(
    baseUrl: base,
    appId: 'dream_manga_reader',
    token: otherToken,
  ));
  final raw = await other.readSummary('e2e-user', key: summaryKey);
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  check(decoded['level'] == 42, '另一个登录用户能读公开摘要（社区页那条路）');

  var anonDenied = false;
  final anon = HertzClient(HertzClientOptions(
    baseUrl: base,
    appId: 'dream_manga_reader',
    token: '',
  ));
  try {
    await anon.readSummary('e2e-user', key: summaryKey);
  } on HertzException catch (e) {
    anonDenied = e.isUnauthorized;
  }
  check(anonDenied, '匿名读被 401（当前设计如此，不是 bug）');

  // ── 删除 ──
  await client.remove(key);
  var gone = false;
  try {
    await client.load(key);
  } on HertzException catch (e) {
    gone = e.isNotFound;
  }
  check(gone, 'remove 之后 load 是 404');

  print('\n----------------------------------------');
  print('共 $_checks 项，失败 $_fails 项');
  print(_fails == 0 ? 'RESULT: 全部通过' : 'RESULT: 有失败');
  if (_fails != 0) exitCode = 1;
}

bool listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
