import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/core/source/source_repository.dart';
import 'package:dream_manga_reader/core/storage/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fault_http_server.dart';

/// 回归 E2:源仓库加载的三处脆弱点。
///
/// 1. `load()` 只有 `finally` 没有 `catch`,而它的兜底路径(`_loadFromCache`)
///    自己会因为缓存里少一个脚本抛 `PathNotFoundException` —— 直接把启动带崩。
/// 2. `_loadFromUrl` 先写 index.json 再逐个下脚本:某个脚本 404 就在缓存里留下
///    一份「清单指向不存在的脚本」的坏缓存,此后每次离线启动都踩它。
/// 3. `_loadFromCache` 缺文件时整套源都读不出来,而不是跳过那一个源。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalSources = List<SourceMeta>.of(registeredSources);
  late Directory cacheDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cacheDirectory =
        await Directory.systemTemp.createTemp('source-repository-load-');
  });

  tearDown(() async {
    registeredSources = List<SourceMeta>.of(originalSources);
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  });

  Future<SourceRepository> repository() async => SourceRepository.forTesting(
        preferences: await SharedPreferences.getInstance(),
        secrets: _MemorySecretStore(),
        cacheDirectory: cacheDirectory,
        // 桌面回退会去读仓库根的 sources_local/。开发机上那里有十几个真源,
        // 不挡住的话「缓存全坏 → 一个源都不剩」在本地永远是假的。
        devDirectory: Directory('${cacheDirectory.path}/no-dev-sources'),
      );

  String manifest(List<String> ids) => jsonEncode({
        'schema': 1,
        'sources': [
          for (final id in ids)
            {'id': id, 'name': id, 'script': '$id.js'},
        ],
      });

  Future<void> writeCache(List<String> ids, {List<String>? withScripts}) async {
    final scripts = withScripts ?? ids;
    await File('${cacheDirectory.path}/index.json')
        .writeAsString(manifest(ids));
    for (final id in scripts) {
      await File('${cacheDirectory.path}/$id.js').writeAsString('// $id');
    }
  }

  /// 引擎自带的内置源(B站)始终在表里,断言时排掉。
  List<String> scriptIds() => [
        for (final s in registeredSources)
          if (s.id != kBiliSourceId) s.id,
      ];

  group('loading from a half-broken cache', () {
    test('skips the sources whose script file is gone', () async {
      await writeCache(['a', 'b', 'c'], withScripts: ['a', 'c']);
      final repo = await repository();

      await repo.load();

      expect(scriptIds(), ['a', 'c'], reason: '少了脚本的源跳过,其余照常可用');
      expect(repo.status.origin, SourceRepoOrigin.cache);
    });

    test('an entirely broken cache leaves the app running with no sources',
        () async {
      await writeCache(['a', 'b'], withScripts: const []);
      final repo = await repository();

      await repo.load();

      expect(scriptIds(), isEmpty);
      expect(registeredSources.map((s) => s.id), [kBiliSourceId],
          reason: '内置源不受影响');
    });

    test('a malformed manifest does not escape load()', () async {
      await File('${cacheDirectory.path}/index.json')
          .writeAsString('not json at all');
      final repo = await repository();

      await expectLater(repo.load(), completes);
      expect(scriptIds(), isEmpty);
    });

    test('a manifest whose sources key is not a list does not throw', () async {
      await File('${cacheDirectory.path}/index.json')
          .writeAsString('{"schema":1,"sources":"nope"}');
      final repo = await repository();

      await expectLater(repo.load(), completes);
      expect(scriptIds(), isEmpty);
    });
  });

  group('fetching a repository over HTTP', () {
    late FaultHttpServer server;
    HttpOverrides? savedOverrides;

    setUp(() async {
      // TestWidgetsFlutterBinding 装了一个把所有请求打成 400 的 HttpOverrides;
      // 这一组要真的连本地测试服务器。
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      server = await FaultHttpServer.start();
    });
    tearDown(() async {
      await server.close();
      HttpOverrides.global = savedOverrides;
    });

    Future<SourceRepository> repoFor(String url) async {
      final repo = await repository();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sources.repoUrl', url);
      return repo;
    }

    test('a complete repository is cached and loaded', () async {
      server.addText('/index.json', manifest(['a', 'b']),
          contentType: 'application/json');
      server.addText('/a.js', '// a', contentType: 'text/javascript');
      server.addText('/b.js', '// b', contentType: 'text/javascript');

      final repo = await repoFor(server.baseUri.toString());
      await repo.load();

      expect(scriptIds(), ['a', 'b']);
      expect(File('${cacheDirectory.path}/index.json').existsSync(), isTrue);
      expect(File('${cacheDirectory.path}/b.js').existsSync(), isTrue);
    });

    test('a 404 on one script leaves the previous cache untouched', () async {
      // 缓存里先有一套能用的源。
      await writeCache(['old']);

      // 新清单里有两个源,但第二个脚本 404。
      server.addText('/index.json', manifest(['a', 'b']),
          contentType: 'application/json');
      server.addText('/a.js', '// a', contentType: 'text/javascript');
      // /b.js 没登记 → 404

      final repo = await repoFor(server.baseUri.toString());
      await repo.load();

      // 拉取整体失败 → 回退到缓存,而缓存必须还是**原来那套**,
      // 不能是「index.json 写了 a、b,磁盘上只有 a.js」的半成品。
      expect(scriptIds(), ['old'], reason: '失败的拉取不该污染缓存');
      expect(File('${cacheDirectory.path}/old.js').existsSync(), isTrue);
      expect(File('${cacheDirectory.path}/a.js').existsSync(), isFalse,
          reason: '没有全部成功,一个字节都不该落进缓存');
      expect(jsonDecode(File('${cacheDirectory.path}/index.json')
              .readAsStringSync())['sources'],
          hasLength(1));
      expect(repo.status.origin, SourceRepoOrigin.cacheAfterFailure);
    });

    test('a 404 with no usable cache reports the failure and stays empty',
        () async {
      server.addText('/index.json', manifest(['a']),
          contentType: 'application/json');
      // /a.js 没登记 → 404

      final repo = await repoFor(server.baseUri.toString());
      await repo.load();

      expect(scriptIds(), isEmpty);
      expect(repo.status.origin, SourceRepoOrigin.failed);
      expect(Directory('${cacheDirectory.path}.staging').existsSync(), isFalse,
          reason: '暂存目录必须清掉');
    });

    test('a manifest entry that escapes the cache directory is skipped',
        () async {
      // 清单来自远程仓库:不能让它决定往哪写文件。
      server.addText(
        '/index.json',
        jsonEncode({
          'schema': 1,
          'sources': [
            {'id': 'evil', 'name': 'evil', 'script': '../../evil.js'},
            {'id': 'ok', 'name': 'ok', 'script': 'ok.js'},
          ],
        }),
        contentType: 'application/json',
      );
      server.addText('/ok.js', '// ok', contentType: 'text/javascript');

      final repo = await repoFor(server.baseUri.toString());
      await repo.load();

      expect(scriptIds(), ['ok']);
      expect(File('${cacheDirectory.parent.path}/evil.js').existsSync(),
          isFalse);
    });
  });
}

class _MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
