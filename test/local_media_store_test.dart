import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/app/local_media_store.dart';
import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local-media-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  LocalMediaStore newStore({bool Function(String location)? existsProbe}) =>
      LocalMediaStore(
        rootProvider: () async => root.path,
        existsProbe: existsProbe,
      );

  File indexFile() => File('${root.path}${Platform.pathSeparator}index.json');
  File backupFile() => File('${indexFile().path}.backup');
  File tempFile() => File('${indexFile().path}.tmp');

  /// 根目录下直接子项的**文件名**集合(排序后),用来断言落盘产物。
  Future<List<String>> fileNames() async {
    final names = [
      for (final entity in await root.list().toList())
        entity.path.split(Platform.pathSeparator).last,
    ]..sort();
    return names;
  }

  List<Map<String, Object?>> exportedLibraries(Map<String, Object?> data) => [
        for (final entry in (data['libraries'] as List?) ?? const [])
          if (entry is Map) Map<String, Object?>.from(entry),
      ];

  List<Map<String, Object?>> exportedItems(Map<String, Object?> library) => [
        for (final entry in (library['items'] as List?) ?? const [])
          if (entry is Map) Map<String, Object?>.from(entry),
      ];

  LocalMediaItem item({
    String id = '',
    String libraryId = '',
    String title = '第一话',
    required String location,
    int? season,
    int? episode,
    int sizeBytes = 1024,
    int? modifiedAt,
    int? durationMs,
    List<LocalSubtitle> subtitles = const [],
    String? thumbPath,
    int addedAt = 0,
    int? lastPlayedAt,
  }) =>
      LocalMediaItem(
        id: id,
        libraryId: libraryId,
        title: title,
        location: location,
        season: season,
        episode: episode,
        sizeBytes: sizeBytes,
        modifiedAt: modifiedAt,
        durationMs: durationMs,
        subtitles: subtitles,
        thumbPath: thumbPath,
        addedAt: addedAt,
        lastPlayedAt: lastPlayedAt,
      );

  const folder = LocalLibraryKind.folder;
  const file = LocalLibraryKind.file;

  // ---------------------------------------------------------------- 落盘读回

  test('新建库 + 扫描结果落盘后,新实例 load() 读回一致', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '番剧目录',
      kind: folder,
      path: r'C:\Media\Anime',
    );
    final summary = await store.applyScanResult(library.id, [
      item(
        libraryId: library.id,
        title: '某番 第一话',
        location: r'C:\Media\Anime\Show.S01E01.1080p.mkv',
        season: 1,
        episode: 1,
        modifiedAt: 1700000000000,
        subtitles: const [
          LocalSubtitle(
            location: r'C:\Media\Anime\Show.S01E01.chs.srt',
            label: '简体',
            language: 'zh',
          ),
        ],
      ),
    ]);
    expect(summary.added, 1);
    expect(summary.updated, 0);
    expect(summary.missing, 0);
    expect(await indexFile().exists(), isTrue);

    final reloaded = newStore();
    await reloaded.load();
    expect(reloaded.loadWarning, isNull);
    expect(reloaded.libraries, hasLength(1));
    final read = reloaded.libraries.single;
    expect(read.id, library.id);
    expect(read.name, '番剧目录');
    expect(read.kind, folder);
    expect(read.path, r'C:\Media\Anime');
    expect(read.treeUri, isNull);
    expect(read.addedAt, library.addedAt);
    expect(read.lastScannedAt, greaterThan(0));

    final readItem = reloaded.items(read.id).single;
    expect(readItem.id, isNotEmpty);
    expect(readItem.libraryId, read.id);
    expect(readItem.title, '某番 第一话');
    expect(readItem.location, r'C:\Media\Anime\Show.S01E01.1080p.mkv');
    expect(readItem.season, 1);
    expect(readItem.episode, 1);
    expect(readItem.sizeBytes, 1024);
    expect(readItem.modifiedAt, 1700000000000);
    expect(readItem.subtitles.single.location,
        r'C:\Media\Anime\Show.S01E01.chs.srt');
    expect(readItem.subtitles.single.label, '简体');
    expect(readItem.subtitles.single.language, 'zh');
    store.dispose();
    reloaded.dispose();
  });

  test('markPlayed 落盘后读回 lastPlayedAt 与回填的 durationMs', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '库',
      kind: folder,
      path: r'C:\Media',
    );
    await store.applyScanResult(library.id, [
      item(
        libraryId: library.id,
        location: r'C:\Media\E01.mkv',
        season: 1,
        episode: 1,
      ),
    ]);
    final before = store.items(library.id).single;
    expect(before.durationMs, isNull);
    expect(before.lastPlayedAt, isNull);

    await store.markPlayed(
      before.id,
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 24),
    );
    final after = store.items(library.id).single;
    expect(after.id, before.id);
    expect(after.lastPlayedAt, isNotNull);
    expect(after.durationMs, 24 * 60 * 1000);
    // 播放位置不进本地索引(§5.4:续播位置的权威是 AnimeLibraryStore)。
    expect(jsonEncode(store.exportData()), isNot(contains('position')));

    final reloaded = newStore();
    await reloaded.load();
    final read = reloaded.item(before.id)!;
    expect(read.durationMs, 24 * 60 * 1000);
    expect(read.lastPlayedAt, after.lastPlayedAt);

    // 播放器还没报时长(Duration.zero)时不冲掉已有值。
    await reloaded.markPlayed(
      before.id,
      position: const Duration(seconds: 1),
      duration: Duration.zero,
    );
    expect(reloaded.item(before.id)!.durationMs, 24 * 60 * 1000);
    store.dispose();
    reloaded.dispose();
  });

  test('libraries 按 addedAt 倒序', () async {
    final store = newStore();
    await store.load();
    await store.addLibrary(name: '旧的', kind: folder, path: r'C:\Media\A');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await store.addLibrary(name: '新的', kind: folder, path: r'C:\Media\B');
    expect(
      [for (final library in store.libraries) library.name],
      ['新的', '旧的'],
    );
    store.dispose();
  });

  test('items 按剧集顺序排序,不按插入顺序', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '库',
      kind: folder,
      path: r'C:\Media',
    );
    await store.applyScanResult(library.id, [
      item(
        libraryId: library.id,
        title: '第 10 话',
        location: r'C:\Media\Ep.10.mkv',
        season: 1,
        episode: 10,
      ),
      item(
        libraryId: library.id,
        location: r'C:\Media\ZZZ.mkv',
        title: 'ZZZ 花絮',
        // 无集号的条目按 §5.3 用大数当集号,沉到带集号的之后。
        season: 1,
      ),
      item(
        libraryId: library.id,
        title: '第 9 话',
        location: r'C:\Media\Ep.9.mkv',
        season: 1,
        episode: 9,
      ),
      item(
        libraryId: library.id,
        title: '第 2 话',
        location: r'C:\Media\Ep.2.mkv',
        season: 1,
        episode: 2,
      ),
      item(
        libraryId: library.id,
        title: '第 1 话',
        location: r'C:\Media\Ep.1.mkv',
        season: 1,
        episode: 1,
      ),
    ]);
    expect(
      [for (final value in store.items(library.id)) value.title],
      ['第 1 话', '第 2 话', '第 9 话', '第 10 话', 'ZZZ 花絮'],
    );
    store.dispose();
  });

  test('变更会通知监听器', () async {
    final store = newStore();
    await store.load();
    var notified = 0;
    store.addListener(() => notified++);
    final library = await store.addLibrary(
      name: '库',
      kind: folder,
      path: r'C:\Media',
    );
    expect(notified, 1);
    await store.applyScanResult(library.id, [
      item(libraryId: library.id, location: r'C:\Media\E01.mkv', episode: 1),
    ]);
    expect(notified, 2);
    await store.markPlayed(
      store.items(library.id).single.id,
      position: Duration.zero,
      duration: const Duration(minutes: 1),
    );
    expect(notified, 3);
    store.dispose();
  });

  test('dispose 后不再通知监听器', () async {
    final store = newStore();
    await store.load();
    var notified = 0;
    store.addListener(() => notified++);
    store.dispose();
    await store.addLibrary(name: '库', kind: folder, path: r'C:\Media');
    expect(notified, 0);
  });

  // ------------------------------------------------------------------ 去重

  test('同 path 第二次抛 duplicateLocation(Windows 下大小写不同也算同一条)', () async {
    final store = newStore();
    await store.load();
    await store.addLibrary(name: 'a', kind: folder, path: r'C:\Media\Anime');
    final duplicate =
        Platform.isWindows ? r'c:\MEDIA\anime' : r'C:\Media\Anime';
    await expectLater(
      store.addLibrary(name: 'b', kind: folder, path: duplicate),
      throwsA(
        isA<LocalMediaException>().having(
          (error) => error.reason,
          'reason',
          LocalMediaError.duplicateLocation,
        ),
      ),
    );
    expect(store.libraries, hasLength(1));
    expect(store.libraries.single.name, 'a');
    store.dispose();
  });

  test('同 treeUri 第二次抛 duplicateLocation', () async {
    const uri =
        'content://com.android.externalstorage.documents/tree/primary%3AMovies';
    final store = newStore();
    await store.load();
    await store.addLibrary(name: 'a', kind: folder, treeUri: uri);
    await expectLater(
      store.addLibrary(name: 'b', kind: folder, treeUri: uri),
      throwsA(
        isA<LocalMediaException>().having(
          (error) => error.reason,
          'reason',
          LocalMediaError.duplicateLocation,
        ),
      ),
    );
    expect(store.libraries, hasLength(1));
    store.dispose();
  });

  test('没有 path/treeUri 的 kind:file 库不参与去重', () async {
    final store = newStore();
    await store.load();
    await store.addLibrary(name: '选的文件', kind: file);
    await store.addLibrary(name: '又选的文件', kind: file);
    expect(store.libraries, hasLength(2));
    store.dispose();
  });

  test('addLibrary 丢掉空 location 的条目,同 dedupeKey 只取一条', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '选的文件',
      kind: file,
      items: [
        item(title: '空的', location: '  '),
        item(title: '第一次', location: r'C:\Media\x.mp4'),
        item(title: '重复', location: r'C:\Media\x.mp4'),
        item(title: '另一个', location: r'C:\Media\y.mp4'),
      ],
    );
    final values = store.items(library.id);
    expect(values, hasLength(2));
    expect(
      [for (final value in values) value.location],
      containsAll([r'C:\Media\x.mp4', r'C:\Media\y.mp4']),
    );
    // 同一批里 dedupeKey 相同时保留**第一条**(标题是第一次那条)。
    final kept = values.firstWhere((value) => value.location.endsWith('x.mp4'));
    expect(kept.title, '第一次');
    expect(kept.libraryId, library.id);
    store.dispose();
  });

  // -------------------------------------------------------------- 扫描合并

  test('applyScanResult 统计新增/刷新/缺失', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '库',
      kind: folder,
      path: r'C:\Media',
    );
    var summary = await store.applyScanResult(library.id, [
      item(libraryId: library.id, location: r'C:\Media\E01.mkv', episode: 1),
      item(libraryId: library.id, location: r'C:\Media\E02.mkv', episode: 2),
    ]);
    expect(summary.added, 2);
    expect(summary.updated, 0);
    expect(summary.missing, 0);

    summary = await store.applyScanResult(library.id, [
      item(
        libraryId: library.id,
        title: '第一话 重制',
        location: r'C:\Media\E01.mkv',
        episode: 1,
        sizeBytes: 2048,
      ),
      item(libraryId: library.id, location: r'C:\Media\E03.mkv', episode: 3),
    ]);
    expect(summary.added, 1);
    expect(summary.updated, 1);
    expect(summary.missing, 1);
    store.dispose();
  });

  test('重扫保留 id/addedAt/lastPlayedAt/durationMs/thumbPath,刷新其余字段', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '库',
      kind: folder,
      path: r'C:\Media',
      items: [
        item(
          title: 'E01 旧标题',
          location: r'C:\Media\E01.mkv',
          season: 1,
          episode: 1,
          sizeBytes: 100,
          modifiedAt: 1,
          durationMs: 90000,
          thumbPath: 'e01.jpg',
          addedAt: 12345,
        ),
      ],
    );
    final before = store.items(library.id).single;
    expect(before.addedAt, 12345);
    await store.markPlayed(
      before.id,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 90),
    );

    final summary = await store.applyScanResult(library.id, [
      item(
        title: 'E01 新标题',
        location: r'C:\Media\E01.mkv',
        season: 2,
        episode: 5,
        sizeBytes: 200,
        modifiedAt: 2,
        subtitles: const [
          LocalSubtitle(location: r'C:\Media\E01.srt', label: 'zh'),
        ],
      ),
    ]);
    expect(summary.added, 0);
    expect(summary.updated, 1);
    final after = store.items(library.id).single;
    // id 是进度记录的 episodeId,重扫绝不能变。
    expect(after.id, before.id);
    expect(after.addedAt, 12345);
    expect(after.durationMs, 90000);
    expect(after.thumbPath, 'e01.jpg');
    expect(after.lastPlayedAt, isNotNull);
    expect(after.title, 'E01 新标题');
    expect(after.season, 2);
    expect(after.episode, 5);
    expect(after.sizeBytes, 200);
    expect(after.modifiedAt, 2);
    expect(after.subtitles.single.label, 'zh');
    store.dispose();
  });

  test('消失的条目保留在索引里(由 UI 灰显),不删除', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '库',
      kind: folder,
      path: r'C:\Media',
    );
    await store.applyScanResult(library.id, [
      item(libraryId: library.id, location: r'C:\Media\E01.mkv', episode: 1),
      item(libraryId: library.id, location: r'C:\Media\E02.mkv', episode: 2),
    ]);
    final summary = await store.applyScanResult(library.id, []);
    expect(summary.added, 0);
    expect(summary.updated, 0);
    expect(summary.missing, 2);
    expect(store.items(library.id), hasLength(2));

    final reloaded = newStore();
    await reloaded.load();
    expect(reloaded.items(library.id), hasLength(2));
    store.dispose();
    reloaded.dispose();
  });

  test('扫描结果内的重复 dedupeKey 只算一条', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '库',
      kind: folder,
      path: r'C:\Media',
    );
    final summary = await store.applyScanResult(library.id, [
      item(title: 'a', location: r'C:\Media\E01.mkv'),
      item(title: 'b', location: r'C:\Media\E01.mkv'),
    ]);
    expect(summary.added, 1);
    expect(store.items(library.id), hasLength(1));
    store.dispose();
  });

  test('applyScanResult / markPlayed 对未知 id 抛领域异常', () async {
    final store = newStore();
    await store.load();
    await expectLater(
      store.applyScanResult('nope', const []),
      throwsA(
        isA<LocalMediaException>().having(
          (error) => error.reason,
          'reason',
          LocalMediaError.libraryNotFound,
        ),
      ),
    );
    await expectLater(
      store.markPlayed(
        'nope',
        position: Duration.zero,
        duration: Duration.zero,
      ),
      throwsA(
        isA<LocalMediaException>().having(
          (error) => error.reason,
          'reason',
          LocalMediaError.itemNotFound,
        ),
      ),
    );
    store.dispose();
  });

  // ---------------------------------------------------------- 索引损坏与恢复

  test('非法 JSON:load() 不抛,空库 + loadWarning', () async {
    await indexFile().writeAsString('{ 这不是 JSON');
    final store = newStore();
    await store.load();
    expect(store.loadWarning, isNotNull);
    expect(store.libraries, isEmpty);
    expect(store.allItems, isEmpty);
    store.dispose();
  });

  test('结构不对(没有 libraries 数组)同样算损坏', () async {
    await indexFile().writeAsString(jsonEncode({'version': 1, 'nope': []}));
    final store = newStore();
    await store.load();
    expect(store.loadWarning, isNotNull);
    expect(store.libraries, isEmpty);
    store.dispose();
  });

  test('index.json 损坏时退到 index.json.backup', () async {
    final seed = newStore();
    await seed.load();
    await seed.addLibrary(name: '只该出现在备份里', kind: folder, path: r'C:\A');
    await seed.addLibrary(name: '后加的', kind: folder, path: r'C:\B');
    seed.dispose();
    expect(await backupFile().exists(), isTrue);

    await indexFile().writeAsString('坏掉的索引');
    final store = newStore();
    await store.load();
    expect(store.loadWarning, isNull);
    expect(store.libraries, hasLength(1));
    expect(store.libraries.single.name, '只该出现在备份里');
    // 备份被回写成正式索引。
    expect(parseIndex(await indexFile().readAsString()), isNotNull);
    store.dispose();
  });

  test('index.json 不存在时从备份恢复', () async {
    final seed = newStore();
    await seed.load();
    await seed.addLibrary(name: '备份里的', kind: folder, path: r'C:\A');
    await seed.addLibrary(name: '后加的', kind: folder, path: r'C:\B');
    seed.dispose();
    await indexFile().delete();

    final store = newStore();
    await store.load();
    expect(store.loadWarning, isNull);
    expect(store.libraries.single.name, '备份里的');
    expect(await indexFile().exists(), isTrue);
    store.dispose();
  });

  test('全新安装(没有索引文件)不算损坏', () async {
    final store = newStore();
    await store.load();
    expect(store.loadWarning, isNull);
    expect(store.libraries, isEmpty);
    store.dispose();
  });

  test('根目录不可用:load() 不抛,变更失败后内存不留脏状态', () async {
    final store = LocalMediaStore(
      rootProvider: () async => throw const FileSystemException('不可写'),
    );
    await store.load();
    expect(store.loadWarning, isNotNull);
    expect(store.libraries, isEmpty);
    await expectLater(
      store.addLibrary(name: '库', kind: folder, path: r'C:\Media'),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.libraries, isEmpty);
    store.dispose();
  });

  // ------------------------------------------------------------------ 原子写

  test('原子写:不残留 .tmp,旧索引留成 .backup', () async {
    final store = newStore();
    await store.load();
    await store.addLibrary(name: 'a', kind: folder, path: r'C:\A');
    expect(await fileNames(), ['index.json']);
    expect(await tempFile().exists(), isFalse);

    await store.addLibrary(name: 'b', kind: folder, path: r'C:\B');
    expect(await fileNames(), ['index.json', 'index.json.backup']);
    expect(await tempFile().exists(), isFalse);
    store.dispose();
  });

  // ------------------------------------------------------------------ 硬化

  test('localSafeName 抹平路径分隔符与路径穿越段', () {
    expect(localSafeName('../../evil'), '.._.._evil');
    expect(localSafeName('../../evil'), isNot(contains('/')));
    expect(localSafeName(r'C:\Windows\system32'), 'C__Windows_system32');
    expect(localSafeName(r'C:\Windows\system32'), isNot(contains(r'\')));
    for (final hostile in ['中文🎬', '../../中文/动画', r'..\..\x', 'a b']) {
      final safe = localSafeName(hostile);
      expect(RegExp(r'^[A-Za-z0-9_.-]*$').hasMatch(safe), isTrue,
          reason: 'localSafeName($hostile) = $safe');
    }
  });

  test('库名/条目名含 ../、C:\\、中文、emoji 时不会写到根目录之外', () async {
    final media = File('${root.path}${Platform.pathSeparator}秘密🎬.mp4');
    await media.writeAsString('video');
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: r'../../中文🎬/C:\evil',
      kind: folder,
      path: r'C:\用户\真实姓名\动画',
    );
    await store.applyScanResult(library.id, [
      item(
        libraryId: library.id,
        title: r'../../坏标题',
        location: media.path,
        season: 1,
        episode: 1,
      ),
    ]);
    // 落盘产物只有索引本身(和上一份备份),没有任何按用户输入拼出来的目录/文件名,
    // 用户自己的媒体文件也照旧躺在原处。
    expect(
      await fileNames(),
      containsAll(['index.json', 'index.json.backup', '秘密🎬.mp4']),
    );
    expect(await fileNames(), hasLength(3));
    expect(await media.exists(), isTrue);
    // 库/条目的 id 是落盘安全的段(会参与 M2 缩略图 / 路线 B 导入目录的拼接)。
    expect(localSafeName(library.id), library.id);
    expect(localSafeName(store.allItems.single.id), store.allItems.single.id);
    // 展示名不做硬化(硬化规则会把中文/emoji 全变成 `_`),但位置仍然是可用的绝对路径。
    expect(store.libraries.single.name, r'../../中文🎬/C:\evil');

    final exported = exportedLibraries(store.exportData()).single;
    expect(localSafeName(exported['id']! as String), exported['id']);
    store.dispose();
  });

  test('索引里不合规的 id 读回时被硬化', () async {
    await indexFile().writeAsString(jsonEncode({
      'version': 1,
      'libraries': [
        {
          'id': '../../evil',
          'name': '../../evil',
          'kind': 'folder',
          'path': r'C:\Media',
          'addedAt': 1,
          'lastScannedAt': 2,
          'items': [
            {
              'id': r'..\..\evil',
              'libraryId': '../../evil',
              'title': 'x',
              'location': r'C:\Media\x.mp4',
              'sizeBytes': 1,
              'addedAt': 3,
            },
            {
              'id': '',
              'libraryId': '../../evil',
              'title': 'y',
              'location': r'C:\Media\y.mp4',
              'sizeBytes': 1,
              'addedAt': 4,
            },
          ],
        },
      ],
    }));
    final store = newStore();
    await store.load();
    expect(store.loadWarning, isNull);
    final library = store.libraries.single;
    expect(library.id, isNot('../../evil'));
    expect(localSafeName(library.id), library.id);
    expect(library.name, '../../evil');
    final values = store.items(library.id);
    expect(values, hasLength(2));
    for (final value in values) {
      expect(value.id, isNotEmpty);
      expect(localSafeName(value.id), value.id);
      expect(value.libraryId, library.id);
    }
    expect(values.map((value) => value.id).toSet(), hasLength(2));
    store.dispose();
  });

  // ---------------------------------------------------------------- 可用性

  test('isAvailable:注入的探针为假时不可用,content:// 恒为可用', () async {
    final store =
        newStore(existsProbe: (location) => location.endsWith('ok.mp4'));
    await store.load();
    expect(store.isAvailable(item(location: r'D:\a\ok.mp4')), isTrue);
    expect(store.isAvailable(item(location: r'D:\a\missing.mp4')), isFalse);
    expect(
      store.isAvailable(item(location: 'content://media/external/video/1')),
      isTrue,
    );
    expect(store.isAvailable(item(location: '   ')), isFalse);
    store.dispose();
  });

  test('isAvailable:默认实现按文件系统判断', () async {
    final media = File('${root.path}${Platform.pathSeparator}real.mp4');
    await media.writeAsString('video');
    final store = newStore();
    await store.load();
    expect(store.isAvailable(item(location: media.path)), isTrue);
    expect(store.isAvailable(item(location: '${media.path}.gone')), isFalse);
    store.dispose();
  });

  // -------------------------------------------------------------- 导入导出

  test('exportData(includeLocations: false) 不含任何位置字段', () async {
    final store = newStore();
    await store.load();
    await store.addLibrary(
      name: '库',
      kind: folder,
      path: r'C:\Media',
      treeUri: 'content://tree/1',
      items: [
        item(
          location: r'C:\Media\E01.mkv',
          season: 1,
          episode: 1,
          subtitles: const [
            LocalSubtitle(location: r'C:\Media\E01.srt', label: 'zh'),
          ],
        ),
      ],
    );

    final full = exportedLibraries(store.exportData()).single;
    expect(full['path'], r'C:\Media');
    expect(full['treeUri'], 'content://tree/1');
    expect(exportedItems(full).single['location'], r'C:\Media\E01.mkv');

    final bare =
        exportedLibraries(store.exportData(includeLocations: false)).single;
    expect(bare.containsKey('path'), isFalse);
    expect(bare.containsKey('treeUri'), isFalse);
    expect(bare['name'], '库');
    final bareItem = exportedItems(bare).single;
    expect(bareItem.containsKey('location'), isFalse);
    expect(bareItem.containsKey('subtitles'), isFalse);
    expect(bareItem['title'], isNotEmpty);
    expect(jsonEncode(bare), isNot(contains('location')));
    expect(jsonEncode(bare), isNot(contains('Media')));
    store.dispose();
  });

  test('importData 合并:同 dedupeKey 跳过,新库追加且不覆盖已有条目', () async {
    final store = newStore();
    await store.load();
    await store.addLibrary(name: '已有', kind: folder, path: r'C:\Media\A');

    final payload = <String, Object?>{
      'version': 1,
      'libraries': [
        {
          'id': 'x',
          'name': '重复路径',
          'kind': 'folder',
          'path': r'C:\Media\A',
          'addedAt': 5,
          'lastScannedAt': 6,
          'items': <Object?>[],
        },
        {
          'id': 'y',
          'name': '新库',
          'kind': 'folder',
          'path': r'C:\Media\B',
          'addedAt': 7,
          'lastScannedAt': 8,
          'items': [
            {
              'id': 'z',
              'libraryId': 'y',
              'title': 'E01',
              'location': r'C:\Media\B\E01.mkv',
              'sizeBytes': 10,
              'addedAt': 9,
            },
          ],
        },
        {
          'id': 'w',
          'name': '没有位置信息',
          'kind': 'file',
          'addedAt': 1,
          'lastScannedAt': 1,
          'items': <Object?>[],
        },
      ],
    };

    await store.importData(payload);
    expect(store.libraries, hasLength(2));
    expect(
      [for (final library in store.libraries) library.name],
      containsAll(['已有', '新库']),
    );
    final imported = store.libraries.firstWhere((l) => l.name == '新库');
    expect(imported.id, isNot('y'));
    expect(imported.addedAt, 7);
    final importedItem = store.items(imported.id).single;
    expect(importedItem.id, isNot('z'));
    expect(importedItem.libraryId, imported.id);
    expect(importedItem.location, r'C:\Media\B\E01.mkv');

    // 再导一次:同 dedupeKey 全部跳过,库里不再变长。
    await store.importData(payload);
    expect(store.libraries, hasLength(2));
    expect(store.allItems, hasLength(1));

    // 结构不对时不抛、不改索引。
    await store.importData(<String, Object?>{'version': 1});
    expect(store.libraries, hasLength(2));
    store.dispose();
  });

  // ---------------------------------------------------------------- 移除库

  test('removeLibrary 只删索引,磁盘上的源文件仍在', () async {
    final media = File('${root.path}${Platform.pathSeparator}movie.mp4');
    await media.writeAsString('video');
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '库',
      kind: folder,
      path: root.path,
    );
    await store.applyScanResult(library.id, [
      item(
        libraryId: library.id,
        location: media.path,
        season: 1,
        episode: 1,
      ),
    ]);
    expect(store.items(library.id), hasLength(1));

    await store.removeLibrary(library.id);
    expect(store.libraries, isEmpty);
    expect(store.allItems, isEmpty);
    // 用户文件一个都没动。
    expect(await media.exists(), isTrue);
    expect(await media.readAsString(), 'video');

    final reloaded = newStore();
    await reloaded.load();
    expect(reloaded.libraries, isEmpty);
    expect(reloaded.allItems, isEmpty);
    store.dispose();
    reloaded.dispose();
  });

  test('removeLibrary 对未知库抛 libraryNotFound', () async {
    final store = newStore();
    await store.load();
    await expectLater(
      store.removeLibrary('nope'),
      throwsA(
        isA<LocalMediaException>().having(
          (error) => error.reason,
          'reason',
          LocalMediaError.libraryNotFound,
        ),
      ),
    );
    store.dispose();
  });

  test('removeItem 只摘掉这一条:库还在,源文件仍在磁盘上', () async {
    final media = File('${root.path}${Platform.pathSeparator}E01.mp4');
    await media.writeAsString('video');
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(
      name: '库',
      kind: folder,
      path: root.path,
    );
    await store.applyScanResult(library.id, [
      item(libraryId: library.id, location: media.path, episode: 1),
      item(
        libraryId: library.id,
        location: '${media.path}.second',
        episode: 2,
      ),
    ]);
    final target = store.items(library.id).first;
    await store.removeItem(target.id);
    expect(store.item(target.id), isNull);
    expect(store.items(library.id), hasLength(1));
    expect(store.library(library.id), isNotNull);
    expect(store.allItems, hasLength(1));
    // 只删索引:用户文件一个都没动。
    expect(await media.exists(), isTrue);
    expect(await media.readAsString(), 'video');
    // 幂等:再移除一次不抛。
    await store.removeItem(target.id);
    expect(store.items(library.id), hasLength(1));

    final reloaded = newStore();
    await reloaded.load();
    expect(reloaded.item(target.id), isNull);
    expect(reloaded.items(library.id), hasLength(1));
    expect(reloaded.library(library.id), isNotNull);
    store.dispose();
    reloaded.dispose();
  });

  test('removeItem 清到 0 条也不删库,落盘产物只有索引', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(name: '选的文件', kind: file);
    await store.applyScanResult(library.id, [
      item(libraryId: library.id, location: r'C:\Media\only.mp4', episode: 1),
    ]);
    await store.removeItem(store.items(library.id).single.id);
    expect(store.items(library.id), isEmpty);
    expect(store.libraries, hasLength(1));
    expect(await fileNames(), ['index.json', 'index.json.backup']);
    expect(await tempFile().exists(), isFalse);
    // 不存在的 id 静默返回。
    await store.removeItem('nope');
    store.dispose();
  });

  // ------------------------------------------------------------------ 改名

  test('renameLibrary 只改名字,落盘后读回一致', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(name: '选的文件', kind: file);
    await store.renameLibrary(library.id, '  Loki S02  ');
    expect(store.library(library.id)!.name, 'Loki S02');

    final reloaded = newStore();
    await reloaded.load();
    expect(reloaded.library(library.id)!.name, 'Loki S02');
    store.dispose();
    reloaded.dispose();
  });

  test('renameLibrary 拒绝空白名字;库不存在抛 libraryNotFound', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(name: '原名', kind: file);

    await expectLater(
      store.renameLibrary(library.id, '   '),
      throwsA(isA<LocalMediaException>().having(
          (e) => e.reason, 'reason', LocalMediaError.invalidName)),
    );
    await expectLater(
      store.renameLibrary('nope', 'x'),
      throwsA(isA<LocalMediaException>().having(
          (e) => e.reason, 'reason', LocalMediaError.libraryNotFound)),
    );
    expect(store.library(library.id)!.name, '原名');
    store.dispose();
  });

  test('renameItem 存 customTitle;重扫刷新 title 也不冲掉它', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(name: 'Loki', kind: file);
    await store.applyScanResult(library.id, [
      item(
        libraryId: library.id,
        title: 'Loki',
        location: r'C:\Media\Loki.S02E06.mov',
        season: 2,
        episode: 6,
      ),
    ]);
    final target = store.items(library.id).single;
    expect(target.displayTitle, 'Loki');

    await store.renameItem(target.id, '  Loki 第九集  ');
    var read = store.item(target.id)!;
    expect(read.customTitle, 'Loki 第九集');
    expect(read.displayTitle, 'Loki 第九集');
    // 解析出来的 title 不动 —— 用户的名字另外存一份。
    expect(read.title, 'Loki');

    // 重扫:title 跟着文件名刷新,id 与用户改的名字都得留住。
    await store.applyScanResult(library.id, [
      item(
        libraryId: library.id,
        title: 'Loki (2021)',
        location: r'C:\Media\Loki.S02E06.mov',
        season: 2,
        episode: 6,
      ),
    ]);
    read = store.item(target.id)!;
    expect(read.id, target.id);
    expect(read.title, 'Loki (2021)');
    expect(read.displayTitle, 'Loki 第九集');

    // 填回解析出来的原名 = 恢复默认,不留一份多余的 customTitle。
    await store.renameItem(target.id, 'Loki (2021)');
    expect(store.item(target.id)!.customTitle, isNull);
    expect(store.item(target.id)!.displayTitle, 'Loki (2021)');

    // 空白同样表示恢复默认。
    await store.renameItem(target.id, '第九集');
    expect(store.item(target.id)!.customTitle, '第九集');
    await store.renameItem(target.id, '   ');
    expect(store.item(target.id)!.customTitle, isNull);
    expect(store.item(target.id)!.displayTitle, 'Loki (2021)');

    await expectLater(
      store.renameItem('nope', 'x'),
      throwsA(isA<LocalMediaException>().having(
          (e) => e.reason, 'reason', LocalMediaError.itemNotFound)),
    );
    store.dispose();
  });

  test('customTitle 落盘读回;老索引没这个字段也照样读', () async {
    final store = newStore();
    await store.load();
    final library = await store.addLibrary(name: 'Loki', kind: file);
    await store.applyScanResult(library.id, [
      item(
        libraryId: library.id,
        title: 'Loki',
        location: r'C:\Media\a.mov',
        episode: 1,
      ),
    ]);
    final target = store.items(library.id).single;
    await store.renameItem(target.id, '我的第一集');

    final reloaded = newStore();
    await reloaded.load();
    expect(reloaded.item(target.id)!.customTitle, '我的第一集');
    expect(reloaded.item(target.id)!.displayTitle, '我的第一集');

    // 旧索引(手写一份没有 customTitle 的)读回来是「没改过」。
    final legacy = LocalMediaItem.fromJson(const {
      'id': 'x',
      'libraryId': 'y',
      'title': 'Loki',
      'location': r'C:\Media\a.mov',
      'sizeBytes': 0,
      'addedAt': 0,
    });
    expect(legacy.customTitle, isNull);
    expect(legacy.displayTitle, 'Loki');
    store.dispose();
    reloaded.dispose();
  });

  testWidgets('LocalMediaScope 下发 store,并在索引变更时重建依赖者', (tester) async {

    final store = newStore();
    // testWidgets 的假异步区里真实文件 I/O 不会完成,落盘必须放进 runAsync。
    await tester.runAsync(store.load);
    final key = UniqueKey();
    await tester.pumpWidget(
      LocalMediaScope(
        store: store,
        child: Builder(
          builder: (context) => SizedBox(
            key: key,
            width: LocalMediaScope.of(context).libraries.length.toDouble(),
          ),
        ),
      ),
    );
    expect(tester.widget<SizedBox>(find.byKey(key)).width, 0);

    await tester.runAsync(
      () => store.addLibrary(name: '库', kind: folder, path: r'C:\Media'),
    );
    await tester.pump();
    expect(tester.widget<SizedBox>(find.byKey(key)).width, 1);
    // read 不建立依赖,拿到的是同一个实例。
    expect(LocalMediaScope.read(tester.element(find.byKey(key))), same(store));
    store.dispose();
  });
}

/// 读一眼索引 JSON 是不是合法对象(libraries 数组存在)。
Object? parseIndex(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return null;
  return decoded['libraries'] is List ? decoded : null;
}
