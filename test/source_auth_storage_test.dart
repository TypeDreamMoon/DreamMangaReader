import 'dart:io';

import 'package:dream_manga_reader/app/auth_store.dart';
import 'package:dream_manga_reader/core/source/auth_token.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/core/source/source_repository.dart';
import 'package:dream_manga_reader/core/storage/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecretStore implements SecretStore {
  _MemorySecretStore([Map<String, String>? values])
      : values = Map<String, String>.of(values ?? const {});

  final Map<String, String> values;
  bool failWrites = false;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('secure write failed');
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalSources = List<SourceMeta>.of(registeredSources);
  late Directory cacheDirectory;

  setUp(() async {
    cacheDirectory =
        await Directory.systemTemp.createTemp('source-repository-test-');
  });

  tearDown(() async {
    for (final source in registeredSources) {
      SourceAuth.set(source.id, null);
    }
    registeredSources = List<SourceMeta>.of(originalSources);
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  });

  test('a manifest source cannot claim a built-in source credential key', () {
    // 清单来自远程仓库。若放任 authKey 取任意值,这个源就能拿到用户的 B 站凭据。
    final impostor = SourceMeta.fromJson({
      'id': 'evil_source',
      'name': '伪装源',
      'authKey': kBiliSourceId,
    }, script: 'evil');

    expect(impostor.authKey, kBiliSourceId, reason: '原始字段保留,便于排查');
    expect(impostor.credentialKey, 'evil_source',
        reason: '内置 id 是保留字,必须退回自身 id');

    // 内置源自己用同名 key 不受影响。
    expect(kBiliSourceMeta.credentialKey, kBiliSourceId);

    // 脚本源之间共用不受限制:同一个仓库,同一信任域。
    const shared = SourceMeta(
      id: 'xiaojie_manga',
      name: '晓桀漫画',
      script: 'manga',
      authKey: 'xiaojie_github',
    );
    expect(shared.credentialKey, 'xiaojie_github');
  });

  test('auth store never injects a built-in credential into an impostor',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final secrets = _MemorySecretStore({
      'source.auth.$kBiliSourceId': 'bili-token',
    });
    registeredSources = <SourceMeta>[
      kBiliSourceMeta,
      SourceMeta.fromJson({
        'id': 'evil_source',
        'name': '伪装源',
        'authKey': kBiliSourceId,
      }, script: 'evil'),
    ];

    final store = AuthStore(preferences: prefs, secrets: secrets);
    await store.load();

    expect(SourceAuth.tokenFor(kBiliSourceId), 'bili-token');
    expect(SourceAuth.tokenFor('evil_source'), isNull);
  });

  test('shared auth key resolves one credential for three source kinds', () {
    final novel = SourceMeta.fromJson({
      'id': 'xiaojie_novel',
      'name': '晓桀小说',
      'kind': 'novel',
      'authKey': 'xiaojie_github',
    }, script: 'novel');
    const manga = SourceMeta(
      id: 'xiaojie_manga',
      name: '晓桀漫画',
      script: 'manga',
      authKey: 'xiaojie_github',
    );
    const anime = SourceMeta(
      id: 'xiaojie_anime',
      name: '晓桀动漫',
      script: 'anime',
      kind: 'anime',
      authKey: 'xiaojie_github',
    );
    const picacg = SourceMeta(
      id: 'picacg',
      name: '哔咔漫画',
      script: 'picacg',
    );

    expect(novel.authKey, 'xiaojie_github');
    expect(novel.credentialKey, 'xiaojie_github');
    expect(manga.credentialKey, 'xiaojie_github');
    expect(anime.credentialKey, 'xiaojie_github');
    expect(picacg.credentialKey, 'picacg');
  });

  test('auth load migrates plaintext and injects every shared source',
      () async {
    SharedPreferences.setMockInitialValues({
      'auth.xiaojie_novel.token': 'github-token',
      'auth.xiaojie_novel.username': 'reader',
      'auth.xiaojie_novel.nickname': 'Reader',
    });
    final prefs = await SharedPreferences.getInstance();
    final secrets = _MemorySecretStore();
    registeredSources = const [
      SourceMeta(
        id: 'xiaojie_novel',
        name: '晓桀小说',
        script: '',
        kind: 'novel',
        authKey: 'xiaojie_github',
      ),
      SourceMeta(
        id: 'xiaojie_manga',
        name: '晓桀漫画',
        script: '',
        authKey: 'xiaojie_github',
      ),
      SourceMeta(
        id: 'xiaojie_anime',
        name: '晓桀动漫',
        script: '',
        kind: 'anime',
        authKey: 'xiaojie_github',
      ),
    ];

    final auth = AuthStore(preferences: prefs, secrets: secrets);
    await auth.load();

    expect(await secrets.read('source.auth.xiaojie_github'), 'github-token');
    expect(prefs.containsKey('auth.xiaojie_novel.token'), isFalse);
    expect(auth.isLoggedIn('xiaojie_novel'), isTrue);
    expect(auth.isLoggedIn('xiaojie_manga'), isTrue);
    expect(auth.nicknameOf('xiaojie_anime'), 'Reader');
    expect(SourceAuth.tokenFor('xiaojie_novel'), 'github-token');
    expect(SourceAuth.tokenFor('xiaojie_manga'), 'github-token');
    expect(SourceAuth.tokenFor('xiaojie_anime'), 'github-token');

    await auth.logout('xiaojie_manga');
    expect(await secrets.read('source.auth.xiaojie_github'), isNull);
    expect(auth.isLoggedIn('xiaojie_novel'), isFalse);
    expect(SourceAuth.tokenFor('xiaojie_anime'), isNull);
  });

  test('failed auth migration keeps plaintext token', () async {
    SharedPreferences.setMockInitialValues({
      'auth.failed.token': 'keep-me',
    });
    final prefs = await SharedPreferences.getInstance();
    final secrets = _MemorySecretStore()..failWrites = true;
    registeredSources = const [
      SourceMeta(id: 'failed', name: 'Failed', script: ''),
    ];

    await AuthStore(preferences: prefs, secrets: secrets).load();

    expect(prefs.getString('auth.failed.token'), 'keep-me');
    expect(SourceAuth.tokenFor('failed'), 'keep-me');
  });

  test('auth reload clears a token removed from secure storage', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = _MemorySecretStore({
      'source.auth.reload': 'old-token',
    });
    registeredSources = const [
      SourceMeta(id: 'reload', name: 'Reload', script: ''),
    ];
    final auth = AuthStore(preferences: prefs, secrets: secrets);
    await auth.load();
    expect(SourceAuth.tokenFor('reload'), 'old-token');

    await secrets.delete('source.auth.reload');
    await auth.load();

    expect(auth.isLoggedIn('reload'), isFalse);
    expect(SourceAuth.tokenFor('reload'), isNull);
  });

  test('repository token migrates only after secure readback', () async {
    SharedPreferences.setMockInitialValues({'sources.token': 'repo-token'});
    final prefs = await SharedPreferences.getInstance();
    final secrets = _MemorySecretStore();
    final repository = SourceRepository.forTesting(
      preferences: prefs,
      secrets: secrets,
      cacheDirectory: cacheDirectory,
    );

    await repository.load();

    expect(repository.token, 'repo-token');
    expect(await secrets.read('source.repository.token'), 'repo-token');
    expect(prefs.containsKey('sources.token'), isFalse);
  });

  test('failed repository migration keeps plaintext token', () async {
    SharedPreferences.setMockInitialValues({'sources.token': 'keep-repo'});
    final prefs = await SharedPreferences.getInstance();
    final secrets = _MemorySecretStore()..failWrites = true;
    final repository = SourceRepository.forTesting(
      preferences: prefs,
      secrets: secrets,
      cacheDirectory: cacheDirectory,
    );

    await repository.load();

    expect(repository.token, 'keep-repo');
    expect(prefs.getString('sources.token'), 'keep-repo');
  });

  test('verified secure repository token removes stale plaintext', () async {
    SharedPreferences.setMockInitialValues({'sources.token': 'stale-token'});
    final prefs = await SharedPreferences.getInstance();
    final secrets = _MemorySecretStore({
      'source.repository.token': 'secure-token',
    });
    final repository = SourceRepository.forTesting(
      preferences: prefs,
      secrets: secrets,
      cacheDirectory: cacheDirectory,
    );

    await repository.load();

    expect(repository.token, 'secure-token');
    expect(prefs.containsKey('sources.token'), isFalse);
  });
}
