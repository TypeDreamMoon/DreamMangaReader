import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/source/source_repository.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/core/storage/secret_store.dart';
import 'package:dream_manga_reader/core/sync/sync_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  late Directory sandbox;
  late List<SourceMeta> originalSources;

  setUp(() async {
    originalSources = List<SourceMeta>.of(registeredSources);
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('novel-sync-test-');
  });

  tearDown(() async {
    registeredSources = originalSources;
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('sync source metadata preserves a shared auth key', () async {
    registeredSources = const [
      SourceMeta(
        id: 'xiaojie_novel',
        name: '晓桀小说',
        script: 'source code',
        kind: 'novel',
        needsLogin: true,
        authKey: 'xiaojie_github',
      ),
    ];
    final manga = LibraryStore();
    final novels = NovelLibraryStore();
    await novels.load();

    final blob = SyncData.build(
      manga,
      novels,
      SourceRepository.instance,
      categories: {SyncCategory.novelSources},
    );
    final entries = (blob['library'] as Map)['localSourcesNovel'] as List;

    expect((entries.single as Map)['authKey'], 'xiaojie_github');
    manga.dispose();
    novels.dispose();
  });

  test('source repository sync exports no token and ignores legacy token',
      () async {
    const sentinel = 'DO_NOT_EXPORT_TOKEN_91f4';
    final manga = LibraryStore();
    final novels = NovelLibraryStore();
    await novels.load();
    final prefs = await SharedPreferences.getInstance();
    final repository = SourceRepository.forTesting(
      preferences: prefs,
      secrets: _MemorySecretStore(),
      cacheDirectory: sandbox,
    )..token = 'device-only-token';

    final blob = SyncData.build(
      manga,
      novels,
      repository,
      categories: {SyncCategory.sourceRepo},
    );
    expect(jsonEncode(blob), isNot(contains('device-only-token')));
    expect((blob['sourceRepo'] as Map).containsKey('token'), isFalse);

    await SyncData.apply(
      {
        'v': 1,
        'library': {'v': 1},
        'sourceRepo': {
          'repoUrl': '',
          'localDir': '',
          'token': sentinel,
        },
      },
      manga,
      novels,
      repository,
      modes: {SyncCategory.sourceRepo: false},
    );

    expect(repository.token, 'device-only-token');
    expect(jsonEncode(blob), isNot(contains(sentinel)));
    manga.dispose();
    novels.dispose();
  });

  test('sync build strips local paths and separates novel categories',
      () async {
    final manga = LibraryStore();
    final novels = NovelLibraryStore();
    await novels.load();
    final directory = Directory(
      '${sandbox.path}${Platform.pathSeparator}local-copy',
    );
    await directory.create();
    novels.addLocal(NovelLibraryEntry.local(
      sha256: 'fingerprint',
      title: '同步小说',
      privatePath: directory.path,
      origin: NovelOrigin.localTxt,
    ));
    novels.saveProgress(
      'local:fingerprint',
      const NovelLocator(chapterId: 'c3', fraction: .7),
      updatedAt: 100,
    );

    final blob = SyncData.build(
      manga,
      novels,
      SourceRepository.instance,
      categories: {
        SyncCategory.favorites,
        SyncCategory.history,
        SyncCategory.readerSettings,
      },
    );
    final encoded = jsonEncode(blob);
    final novelData = blob['novels'] as Map;

    expect(novelData['favorites'], hasLength(1));
    expect(novelData['history'], contains('local:fingerprint'));
    expect(novelData['settings'], isA<Map>());
    expect(encoded, isNot(contains(directory.path)));
    manga.dispose();
    novels.dispose();
  });

  test('novel merge keeps metadata and newest locator per stable identity', () {
    Map<String, dynamic> blob(
      int syncedAt,
      Map<String, dynamic> novels,
    ) =>
        {
          'v': 1,
          'syncedAt': syncedAt,
          'library': {'v': 1},
          'novels': {'schema': 1, ...novels},
        };
    final local = blob(100, {
      'favorites': [
        {
          'key': 'local:abc',
          'origin': 'localTxt',
          'fingerprint': 'abc',
          'title': '本地标题',
          'authors': [],
          'favorite': true,
          'addedAt': 10,
        },
      ],
      'historyEntries': [
        {
          'key': 'local:abc',
          'origin': 'localTxt',
          'fingerprint': 'abc',
          'title': '本地标题',
          'authors': [],
          'favorite': true,
          'addedAt': 10,
        },
      ],
      'history': {
        'local:abc': {
          'chapterId': 'c1',
          'fraction': .2,
          'updatedAt': 20,
        },
      },
    });
    final remote = blob(200, {
      'favorites': [
        {
          'key': 'local:abc',
          'origin': 'localTxt',
          'fingerprint': 'abc',
          'title': '云端标题',
          'authors': ['作者'],
          'favorite': true,
          'addedAt': 30,
        },
      ],
      'historyEntries': [
        {
          'key': 'local:abc',
          'origin': 'localTxt',
          'fingerprint': 'abc',
          'title': '云端标题',
          'authors': ['作者'],
          'favorite': true,
          'addedAt': 30,
        },
      ],
      'history': {
        'local:abc': {
          'chapterId': 'c8',
          'fraction': .6,
          'updatedAt': 80,
        },
      },
    });

    final merged = SyncData.merge(local, remote)['novels'] as Map;

    expect((merged['favorites'] as List).single['title'], '云端标题');
    expect(merged['history']['local:abc']['chapterId'], 'c8');
    expect(merged['history']['local:abc']['updatedAt'], 80);
  });

  test('sync apply preserves private path while replacing novel progress',
      () async {
    final manga = LibraryStore();
    final novels = NovelLibraryStore();
    await novels.load();
    final directory = Directory(
      '${sandbox.path}${Platform.pathSeparator}private-copy',
    );
    await directory.create();
    novels.addLocal(NovelLibraryEntry.local(
      sha256: 'abc',
      title: '本机标题',
      privatePath: directory.path,
      origin: NovelOrigin.localTxt,
    ));
    novels.saveProgress(
      'local:abc',
      const NovelLocator(chapterId: 'c1'),
      updatedAt: 10,
    );
    final entry = {
      'key': 'local:abc',
      'origin': 'localTxt',
      'fingerprint': 'abc',
      'title': '同步标题',
      'authors': ['作者'],
      'favorite': true,
      'addedAt': 20,
    };
    final blob = <String, dynamic>{
      'v': 1,
      'syncedAt': 100,
      'library': {'v': 1},
      'novels': {
        'schema': 1,
        'favorites': [entry],
        'historyEntries': [entry],
        'history': {
          'local:abc': {
            'chapterId': 'c7',
            'fraction': .5,
            'updatedAt': 70,
          },
        },
      },
    };

    await SyncData.apply(
      blob,
      manga,
      novels,
      SourceRepository.instance,
      modes: {
        SyncCategory.favorites: false,
        SyncCategory.history: false,
      },
    );

    expect(novels.entryFor('local:abc')?.title, '同步标题');
    expect(novels.entryFor('local:abc')?.privatePath, directory.path);
    expect(novels.progressFor('local:abc')?.chapterId, 'c7');
    manga.dispose();
    novels.dispose();
  });

  test('history-only sync does not also import novel favorite state', () async {
    final manga = LibraryStore();
    final novels = NovelLibraryStore();
    await novels.load();
    final entry = {
      'key': 'remote:source-a:novel-1',
      'origin': 'remote',
      'sourceId': 'source-a',
      'novelId': 'novel-1',
      'title': '仅同步进度',
      'authors': <String>[],
      'favorite': true,
      'addedAt': 20,
    };
    final blob = <String, dynamic>{
      'v': 1,
      'syncedAt': 100,
      'library': {'v': 1},
      'novels': {
        'schema': 1,
        'historyEntries': [entry],
        'history': {
          'remote:source-a:novel-1': {
            'chapterId': 'c2',
            'fraction': .3,
            'updatedAt': 70,
          },
        },
      },
    };

    await SyncData.apply(
      blob,
      manga,
      novels,
      SourceRepository.instance,
      modes: {SyncCategory.history: false},
    );

    expect(novels.entryFor('remote:source-a:novel-1'), isNotNull);
    expect(novels.entryFor('remote:source-a:novel-1')?.favorite, isFalse);
    expect(
      novels.progressFor('remote:source-a:novel-1')?.chapterId,
      'c2',
    );
    manga.dispose();
    novels.dispose();
  });
}
