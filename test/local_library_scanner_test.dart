import 'dart:io';

import 'package:dream_manga_reader/core/local/dart_io_directory_walker.dart';
import 'package:dream_manga_reader/core/local/local_library_scanner.dart';
import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Windows 风格条目：location = 目录 + `\` + 文件名。
LocalFileEntry _windowsFile(
  String directory,
  String name, {
  int size = 1024,
  int? modifiedAt = 1700000000000,
}) =>
    LocalFileEntry(
      location: '$directory\\$name',
      name: name,
      directoryKey: directory,
      size: size,
      modifiedAt: modifiedAt,
    );

/// Android 风格条目：location = 父 document uri + `/` + 文件名。
LocalFileEntry _androidFile(
  String parentUri,
  String name, {
  int size = 2048,
  int? modifiedAt,
}) =>
    LocalFileEntry(
      location: '$parentUri/$name',
      name: name,
      directoryKey: parentUri,
      size: size,
      modifiedAt: modifiedAt,
    );

LocalLibraryScanner _scanner(
  List<LocalFileEntry> entries, {
  bool windows = true,
  int maxItems = 20000,
}) =>
    LocalLibraryScanner(
      walker: InMemoryDirectoryWalker(entries),
      windows: windows,
      maxItems: maxItems,
    );

List<String> _names(List<LocalFileEntry> found) =>
    <String>[for (final LocalFileEntry entry in found) entry.name];

/// 上报跳过数的假 walker：验证扫描器会把 walk 内部的跳过数累加进结果。
class _SkipReportingWalker implements LocalDirectoryWalker, LocalWalkSkipReport {
  _SkipReportingWalker(this.entries, this.skippedDuringWalk);

  final List<LocalFileEntry> entries;

  @override
  final int skippedDuringWalk;

  @override
  Future<List<LocalFileEntry>> walk(
    String root, {
    void Function(int found)? onProgress,
  }) async {
    onProgress?.call(entries.length);
    return entries;
  }
}

void main() {
  group('Windows 风格路径', () {
    test('解析标题与季集号，location/size/mtime 原样搬运', () async {
      const String directory = r'F:\Anime\Show';
      final LocalLibraryScanner scanner = _scanner(<LocalFileEntry>[
        _windowsFile(directory, 'Show.S01E02.1080p.mkv', size: 4096),
        _windowsFile(directory, 'Show.S01E01.1080p.mkv', size: 2048),
        _windowsFile(directory, 'cover.jpg'),
      ]);

      final LocalScanResult result = await scanner.scan(
        libraryId: 'lib-1',
        root: directory,
      );

      expect(result.items, hasLength(2));
      expect(result.items[0].episode, 1);
      expect(result.items[1].episode, 2);
      for (final LocalMediaItem item in result.items) {
        expect(item.title, 'Show');
        expect(item.season, 1);
        expect(item.libraryId, 'lib-1');
        expect(item.durationMs, isNull);
        expect(item.thumbPath, isNull);
        expect(item.lastPlayedAt, isNull);
        // location 原样：不换分隔符、不做 URL 编码。
        expect(item.location, startsWith('$directory\\'));
      }
      expect(result.items[0].location, r'F:\Anime\Show\Show.S01E01.1080p.mkv');
      expect(result.items[0].sizeBytes, 2048);
      expect(result.items[1].sizeBytes, 4096);
      expect(result.items[0].modifiedAt, 1700000000000);
      expect(result.skipped, 1);
      expect(result.truncated, isFalse);
      expect(result.warning, isNull);
    });

    test('id 唯一非空，同一次扫描的 addedAt 一致', () async {
      const String directory = r'F:\Anime\Show';
      final LocalScanResult result = await _scanner(<LocalFileEntry>[
        _windowsFile(directory, 'Show.S01E01.mkv'),
        _windowsFile(directory, 'Show.S01E02.mkv'),
        _windowsFile(directory, 'Show.S01E03.mkv'),
      ]).scan(libraryId: 'lib-x', root: directory);

      final Set<String> ids = <String>{
        for (final LocalMediaItem item in result.items) item.id,
      };
      expect(result.items, hasLength(3));
      expect(ids, hasLength(3));
      expect(ids.every((String id) => id.isNotEmpty), isTrue);
      final Set<int> addedAt = <int>{
        for (final LocalMediaItem item in result.items) item.addedAt,
      };
      expect(addedAt, hasLength(1));
      expect(addedAt.single, greaterThan(0));
    });

    test('标题清理：字幕组前缀与尾部集号一起吃掉', () async {
      const String directory = r'F:\Anime\Show';
      final LocalScanResult result = await _scanner(<LocalFileEntry>[
        _windowsFile(directory, '[Group] Show - 12 [1080p].mkv'),
      ]).scan(libraryId: 'lib-1', root: directory);

      expect(result.items.single.title, 'Show');
      expect(result.items.single.episode, 12);
    });
  });

  group('Android document uri', () {
    const String treeUri =
        'content://com.android.externalstorage.documents/tree/primary%3AAnime/document/primary%3AAnime%2FShow';

    test('uri 没有字典序意义，顺序仍按季集自然序', () async {
      final LocalScanResult result = await _scanner(
        <LocalFileEntry>[
          _androidFile(treeUri, 'Show.E10.mkv'),
          _androidFile(treeUri, 'Show.mkv'),
          _androidFile(treeUri, 'Show.E9.mkv'),
        ],
        windows: false,
      ).scan(libraryId: 'lib-android', root: treeUri);

      expect(result.items, hasLength(3));
      expect(result.items[0].location, '$treeUri/Show.E9.mkv');
      expect(result.items[1].location, '$treeUri/Show.E10.mkv');
      // 无集号的条目沉底（剧场版/整季合辑）。
      expect(result.items[2].location, '$treeUri/Show.mkv');
      expect(result.items[0].episode, 9);
      expect(result.items[1].episode, 10);
      expect(result.items[0].libraryId, 'lib-android');
      expect(result.items[0].sizeBytes, 2048);
      expect(result.items[0].modifiedAt, isNull);
    });
  });

  group('排序', () {
    test('E10 排在 E9 之后，NCOP 这类无集号条目排最后', () async {
      const String directory = r'F:\Anime\Show';
      final LocalScanResult result = await _scanner(<LocalFileEntry>[
        _windowsFile(directory, 'Show.NCOP.mkv'),
        _windowsFile(directory, 'Show.E10.mkv'),
        _windowsFile(directory, 'Show.E9.mkv'),
      ]).scan(libraryId: 'lib-1', root: directory);

      expect(
        <int?>[for (final LocalMediaItem item in result.items) item.episode],
        <int?>[9, 10, null],
      );
    });

    test('同名文件在不同目录时按 location 兜底成全序', () async {
      final LocalScanResult result = await _scanner(<LocalFileEntry>[
        _windowsFile(r'F:\B', 'Show.E01.mkv'),
        _windowsFile(r'F:\A', 'Show.E01.mkv'),
      ]).scan(libraryId: 'lib-1', root: r'F:\');

      expect(result.items, hasLength(2));
      expect(result.items[0].location, r'F:\A\Show.E01.mkv');
      expect(result.items[1].location, r'F:\B\Show.E01.mkv');
    });
  });

  group('字幕配对', () {
    test('同 basename 的 .zh.srt 与 .ass 配到视频上，语言与标签来自文件名', () async {
      const String directory = r'F:\Anime\Show';
      final LocalScanResult result = await _scanner(<LocalFileEntry>[
        _windowsFile(directory, 'Show.S01E02.mkv'),
        _windowsFile(directory, 'Show.S01E02.zh.srt'),
        _windowsFile(directory, 'Show.S01E02.ass'),
        _windowsFile(directory, 'Show.S01E01.mkv'),
      ]).scan(libraryId: 'lib-1', root: directory);

      final LocalMediaItem second = result.items[1];
      expect(second.episode, 2);
      expect(second.subtitles, hasLength(2));
      expect(second.subtitles[0].location, r'F:\Anime\Show\Show.S01E02.zh.srt');
      expect(second.subtitles[0].label, '简体');
      expect(second.subtitles[0].language, 'zh');
      // 推断不出语言时用去扩展名的文件名当标签，至少认得出来是哪个文件。
      expect(second.subtitles[1].label, 'Show.S01E02');
      expect(second.subtitles[1].language, isNull);
      // 同目录的 E01 不该被 E02 的字幕贴上。
      expect(result.items[0].subtitles, isEmpty);
    });

    test('隔壁目录的字幕不配', () async {
      const String first = r'F:\Anime\Show';
      const String other = r'F:\Anime\Show\Extras';
      final LocalScanResult result = await _scanner(<LocalFileEntry>[
        _windowsFile(first, 'Show.S01E01.mkv'),
        _windowsFile(other, 'Show.S01E01.srt'),
      ]).scan(libraryId: 'lib-1', root: first);

      expect(result.items, hasLength(1));
      expect(result.items.single.subtitles, isEmpty);
      // 隔壁的字幕是字幕文件，不算「跳过」。
      expect(result.skipped, 0);
    });

    test('同名但不同 base 的字幕不配（Show.S01E023 不是 Show.S01E02 的字幕）', () async {
      const String directory = r'F:\Anime\Show';
      final LocalScanResult result = await _scanner(<LocalFileEntry>[
        _windowsFile(directory, 'Show.S01E02.mkv'),
        _windowsFile(directory, 'Show.S01E023.srt'),
      ]).scan(libraryId: 'lib-1', root: directory);

      expect(result.items.single.subtitles, isEmpty);
      expect(result.skipped, 0);
    });
  });

  group('skipped 计数', () {
    test('既不是媒体也不是字幕的文件计入 skipped，字幕不计', () async {
      const String directory = r'F:\Anime\Show';
      final LocalScanResult result = await _scanner(<LocalFileEntry>[
        _windowsFile(directory, 'Show.S01E01.mkv'),
        _windowsFile(directory, 'Show.S01E01.zh.srt'),
        _windowsFile(directory, 'cover.jpg'),
        _windowsFile(directory, 'notes.txt'),
        _windowsFile(directory, 'readme'),
        _windowsFile(directory, 'archive.zip'),
      ]).scan(libraryId: 'lib-1', root: directory);

      expect(result.items, hasLength(1));
      expect(result.skipped, 4);
    });

    test('walker 上报的跳过数累加进结果', () async {
      const String directory = r'F:\Anime\Show';
      final LocalLibraryScanner scanner = LocalLibraryScanner(
        walker: _SkipReportingWalker(
          <LocalFileEntry>[
            _windowsFile(directory, 'Show.S01E01.mkv'),
            _windowsFile(directory, 'cover.jpg'),
          ],
          3,
        ),
        windows: true,
      );

      final LocalScanResult result = await scanner.scan(
        libraryId: 'lib-1',
        root: directory,
      );

      expect(result.items, hasLength(1));
      expect(result.skipped, 4);
    });
  });

  group('截断', () {
    test('超过 maxItems：保留排序后的前 N 个并给出提示', () async {
      const String directory = r'F:\Anime\Show';
      final LocalScanResult result = await _scanner(
        <LocalFileEntry>[
          for (int episode = 5; episode >= 1; episode--)
            _windowsFile(directory, 'Show.E0$episode.mkv'),
        ],
        maxItems: 3,
      ).scan(libraryId: 'lib-1', root: directory);

      expect(result.items, hasLength(3));
      expect(
        <int?>[for (final LocalMediaItem item in result.items) item.episode],
        <int?>[1, 2, 3],
      );
      expect(result.truncated, isTrue);
      expect(result.warning, contains('只扫描了前 3 个文件'));
      // 被截断的媒体不算「跳过」——那是两回事。
      expect(result.skipped, 0);
    });

    test('没超过上限时不截断也不提示', () async {
      const String directory = r'F:\Anime\Show';
      final LocalScanResult result = await _scanner(
        <LocalFileEntry>[
          for (int episode = 1; episode <= 4; episode++)
            _windowsFile(directory, 'Show.E0$episode.mkv'),
        ],
        maxItems: 10,
      ).scan(libraryId: 'lib-1', root: directory);

      expect(result.items, hasLength(4));
      expect(result.truncated, isFalse);
      expect(result.warning, isNull);
    });
  });

  group('空目录与失败', () {
    test('空目录：items 空、warning 非空、skipped 0', () async {
      final LocalScanResult result = await _scanner(<LocalFileEntry>[]).scan(
        libraryId: 'lib-1',
        root: r'F:\Anime\Empty',
      );

      expect(result.items, isEmpty);
      expect(result.skipped, 0);
      expect(result.truncated, isFalse);
      expect(result.warning, isNotNull);
      expect(result.warning, isNotEmpty);
    });

    test('只有非媒体文件的目录：items 空、skipped > 0、warning 非空', () async {
      const String directory = r'F:\Anime\Photos';
      final LocalScanResult result = await _scanner(<LocalFileEntry>[
        _windowsFile(directory, 'DSC_0001.jpg'),
        _windowsFile(directory, 'notes.txt'),
      ]).scan(libraryId: 'lib-1', root: directory);

      expect(result.items, isEmpty);
      expect(result.skipped, 2);
      expect(result.warning, isNotNull);
    });

    test('walk 抛 FileSystemException：不崩、items 空、warning 不含完整路径', () async {
      final LocalLibraryScanner scanner = LocalLibraryScanner(
        walker: InMemoryDirectoryWalker(
          const <LocalFileEntry>[],
          error: FileSystemException('拒绝访问', r'F:\Anime\Show'),
        ),
        windows: true,
      );

      final LocalScanResult result = await scanner.scan(
        libraryId: 'lib-1',
        root: r'F:\Anime\Show',
      );

      expect(result.items, isEmpty);
      expect(result.skipped, 0);
      expect(result.truncated, isFalse);
      expect(result.warning, contains('扫描失败'));
      expect(result.warning, contains('拒绝访问'));
      expect(result.warning, isNot(contains(r'F:\Anime\Show')));
      expect(result.warning, isNot(contains('Anime')));
    });

    test('walk 抛带路径的泛型异常：路径被抹成占位符', () async {
      final LocalLibraryScanner scanner = LocalLibraryScanner(
        walker: InMemoryDirectoryWalker(
          const <LocalFileEntry>[],
          error: Exception(r'读取 F:\Anime\Show\a.mkv 失败'),
        ),
        windows: true,
      );

      final LocalScanResult result = await scanner.scan(
        libraryId: 'lib-1',
        root: r'F:\Anime\Show',
      );

      expect(result.warning, contains('扫描失败'));
      expect(result.warning, contains('<路径>'));
      expect(result.warning, isNot(contains('Anime')));
    });

    test('onProgress 透传给 walker', () async {
      const String directory = r'F:\Anime\Show';
      final List<int> progress = <int>[];
      await _scanner(<LocalFileEntry>[
        _windowsFile(directory, 'Show.S01E01.mkv'),
        _windowsFile(directory, 'Show.S01E02.mkv'),
      ]).scan(
        libraryId: 'lib-1',
        root: directory,
        onProgress: progress.add,
      );

      expect(progress, isNotEmpty);
      expect(progress.last, 2);
    });
  });

  group('DartIoDirectoryWalker', () {
    test('真实递归：跳过隐藏目录与 System Volume Information，父目录键正确', () async {
      final Directory temp = Directory.systemTemp.createTempSync('local_scan_');
      final String separator = Platform.pathSeparator;
      try {
        File('${temp.path}${separator}Show.E01.mkv').writeAsStringSync('first');
        File('${temp.path}${separator}cover.jpg').writeAsStringSync('cover');
        final Directory sub = Directory('${temp.path}${separator}Sub')
          ..createSync();
        File('${sub.path}${separator}Show.E02.mkv').writeAsStringSync('second');
        File('${sub.path}${separator}Show.E02.zh.srt').writeAsStringSync('sub');
        Directory('${temp.path}${separator}System Volume Information')
            .createSync();
        File('${temp.path}${separator}System Volume Information'
                '${separator}pagefile.sys')
            .writeAsStringSync('hidden');
        Directory('${temp.path}$separator.hidden').createSync();
        File('${temp.path}$separator.hidden${separator}secret.mkv')
            .writeAsStringSync('hidden');

        final DartIoDirectoryWalker walker = DartIoDirectoryWalker();
        final List<LocalFileEntry> found = await walker.walk(temp.path);

        expect(
          _names(found),
          containsAll(<String>[
            'Show.E01.mkv',
            'Show.E02.mkv',
            'Show.E02.zh.srt',
            'cover.jpg',
          ]),
        );
        expect(_names(found), isNot(contains('pagefile.sys')));
        expect(_names(found), isNot(contains('secret.mkv')));
        expect(walker.skippedDuringWalk, 0);

        final LocalFileEntry entry = found.firstWhere(
          (LocalFileEntry item) => item.name == 'Show.E02.mkv',
        );
        expect(entry.location, File('${sub.path}${separator}Show.E02.mkv').absolute.path);
        expect(entry.directoryKey, sub.absolute.path);
        expect(entry.size, greaterThan(0));
        expect(entry.modifiedAt, isNotNull);

        // 走一遍完整的扫描：两个媒体 + 一个配对上的字幕 + 一张被跳过的图。
        final LocalScanResult result = await LocalLibraryScanner(
          walker: DartIoDirectoryWalker(),
          windows: Platform.isWindows,
        ).scan(libraryId: 'lib-temp', root: temp.path);

        expect(result.items, hasLength(2));
        expect(result.items[0].episode, 1);
        expect(result.items[1].episode, 2);
        expect(result.items[1].subtitles, hasLength(1));
        expect(result.items[1].subtitles.single.language, 'zh');
        expect(result.skipped, 1);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('超过 maxPathLength 的路径计入跳过数', () async {
      final Directory temp = Directory.systemTemp.createTempSync('local_scan_');
      final String separator = Platform.pathSeparator;
      try {
        File('${temp.path}${separator}Show.E01.mkv').writeAsStringSync('a');
        File('${temp.path}${separator}Show.E02.mkv').writeAsStringSync('b');

        final DartIoDirectoryWalker walker =
            DartIoDirectoryWalker(maxPathLength: 10);
        final List<LocalFileEntry> found = await walker.walk(temp.path);

        expect(found, isEmpty);
        expect(walker.skippedDuringWalk, 2);
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('根目录不存在：walker 抛异常，扫描器转成不含路径的提示', () async {
      final Directory temp = Directory.systemTemp.createTempSync('local_scan_');
      final String missing = '${temp.path}${Platform.pathSeparator}missing';
      try {
        final DartIoDirectoryWalker walker = DartIoDirectoryWalker();
        expect(
          walker.walk(missing),
          throwsA(isA<FileSystemException>()),
        );

        final LocalScanResult result = await LocalLibraryScanner(
          walker: DartIoDirectoryWalker(),
          windows: Platform.isWindows,
        ).scan(libraryId: 'lib-missing', root: missing);

        expect(result.items, isEmpty);
        expect(result.warning, contains('扫描失败'));
        expect(result.warning, contains('不存在或不可读'));
        expect(result.warning, isNot(contains(temp.path)));
      } finally {
        temp.deleteSync(recursive: true);
      }
    });
  });
}
