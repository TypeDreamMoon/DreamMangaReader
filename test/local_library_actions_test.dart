import 'dart:io';

import 'package:dream_manga_reader/app/local_media_store.dart';
import 'package:dream_manga_reader/core/local/local_library_scanner.dart';
import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:dream_manga_reader/features/local/local_library_actions.dart';
import 'package:dream_manga_reader/features/local/local_location_picker.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

late AppLocalizations _l10n;

void main() {
  late Directory root;
  late LocalMediaStore store;

  setUpAll(() async {
    _l10n = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_actions_test');
    store = LocalMediaStore(rootProvider: () async => root.path);
    await store.load();
  });

  tearDown(() async {
    store.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('addFolder cancels quietly when the user backs out of the picker',
      () async {
    final reports = <String>[];
    final picker = _FakePicker();
    final actions = _actions(store, picker: picker, reports: reports);

    expect(await actions.addFolder(), isNull);
    expect(picker.directoryCalls, 1);
    expect(store.libraries, isEmpty);
    expect(reports, isEmpty);
  });

  test('addFolder creates a library and scans it right away', () async {
    final reports = <String>[];
    final folder = Directory('${root.path}${Platform.pathSeparator}Show')
      ..createSync(recursive: true);
    final picker = _FakePicker(
      directory: PickedLocation(
        location: folder.path,
        name: 'Show',
        kind: LocalLibraryKind.folder,
      ),
    );
    final walker = InMemoryDirectoryWalker([
      _entry(folder.path, 'Show.S01E01.mkv', 100),
      _entry(folder.path, 'Show.S01E02.mkv', 200),
    ]);
    final actions =
        _actions(store, picker: picker, walker: walker, reports: reports);

    final library = await actions.addFolder();

    expect(library, isNotNull);
    expect(library!.kind, LocalLibraryKind.folder);
    expect(library.name, 'Show');
    // Windows 上路径就是根;Android 上根是 treeUri。
    expect(library.path, folder.path);
    expect(library.treeUri, isNull);
    expect(store.libraries.length, 1);
    expect(store.items(library.id).length, 2);
    expect(reports.first, _l10n.local_scanning);
    expect(reports.any((m) => m.contains('2')), isTrue);
  });

  test('addFolder reports the duplicate instead of adding twice', () async {
    final reports = <String>[];
    final folder = Directory('${root.path}${Platform.pathSeparator}Dup')
      ..createSync(recursive: true);
    final picker = _FakePicker(
      directory: PickedLocation(
        location: folder.path,
        name: 'Dup',
        kind: LocalLibraryKind.folder,
      ),
    );
    final walker = InMemoryDirectoryWalker([
      _entry(folder.path, 'a.mkv', 10),
    ]);
    final actions =
        _actions(store, picker: picker, walker: walker, reports: reports);

    expect(await actions.addFolder(), isNotNull);
    reports.clear();
    expect(await actions.addFolder(), isNull);
    expect(store.libraries.length, 1);
    expect(reports, [_l10n.local_duplicateLocation]);
  });

  test('addFiles builds a file library and pairs its subtitles', () async {
    final reports = <String>[];
    final folder = Directory('${root.path}${Platform.pathSeparator}Movies')
      ..createSync(recursive: true);
    final video = File('${folder.path}${Platform.pathSeparator}Movie.S01E01.mkv')
      ..writeAsBytesSync(List<int>.filled(2048, 7));
    final other = File('${folder.path}${Platform.pathSeparator}Movie.S01E02.mkv')
      ..writeAsBytesSync(List<int>.filled(4096, 7));
    final subtitle = File('${folder.path}${Platform.pathSeparator}Movie.S01E01.zh.srt')
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n你好\n');
    final picker = _FakePicker(files: [
      PickedLocation(
        location: video.path,
        name: 'Movie.S01E01.mkv',
        kind: LocalLibraryKind.file,
      ),
      PickedLocation(
        location: other.path,
        name: 'Movie.S01E02.mkv',
        kind: LocalLibraryKind.file,
      ),
      PickedLocation(
        location: subtitle.path,
        name: 'Movie.S01E01.zh.srt',
        kind: LocalLibraryKind.file,
      ),
    ]);
    final actions = _actions(store, picker: picker, reports: reports);

    final library = await actions.addFiles();

    expect(library, isNotNull);
    expect(library!.kind, LocalLibraryKind.file);
    // 同一目录 → 库名取目录名,而不是第一个文件名。
    expect(library.name, 'Movies');
    final items = store.items(library.id);
    expect(items.length, 2);
    expect(items.first.title, 'Movie');
    expect(items.first.season, 1);
    expect(items.first.episode, 1);
    expect(items.first.sizeBytes, 2048);
    expect(items.first.modifiedAt, isNotNull);
    expect(items.first.subtitles.length, 1);
    expect(items.first.subtitles.first.label, isNotEmpty);
  });

  test('addFiles refuses a pick with nothing playable in it', () async {
    final reports = <String>[];
    final text = File('${root.path}${Platform.pathSeparator}notes.txt')
      ..writeAsStringSync('hi');
    final picker = _FakePicker(files: [
      PickedLocation(
        location: text.path,
        name: 'notes.txt',
        kind: LocalLibraryKind.file,
      ),
    ]);
    final actions = _actions(store, picker: picker, reports: reports);

    expect(await actions.addFiles(), isNull);
    expect(store.libraries, isEmpty);
    expect(reports.last, _l10n.local_emptyUnsupported);
  });

  test('rescan keeps ids and reports what went missing', () async {
    final reports = <String>[];
    final folder = Directory('${root.path}${Platform.pathSeparator}Rescan')
      ..createSync(recursive: true);
    final picker = _FakePicker(
      directory: PickedLocation(
        location: folder.path,
        name: 'Rescan',
        kind: LocalLibraryKind.folder,
      ),
    );
    final first = InMemoryDirectoryWalker([
      _entry(folder.path, 'a.mkv', 10),
      _entry(folder.path, 'b.mkv', 20),
    ]);
    final actions =
        _actions(store, picker: picker, walker: first, reports: reports);
    final library = (await actions.addFolder())!;
    final before = {
      for (final item in store.items(library.id)) item.dedupeKey(windows: true): item.id,
    };

    // 第二次扫描少了一个文件:条目不该被删,id 也不该变。
    final second = _actions(
      store,
      picker: picker,
      walker: InMemoryDirectoryWalker([_entry(folder.path, 'a.mkv', 10)]),
      reports: reports,
    );
    reports.clear();
    final summary = await second.rescan(store.library(library.id)!);

    expect(summary, isNotNull);
    expect(summary!.missing, 1);
    final after = store.items(library.id);
    expect(after.length, 2);
    for (final item in after) {
      expect(item.id, before[item.dedupeKey(windows: true)]);
    }
    expect(store.library(library.id)!.lastScannedAt, greaterThan(0));
  });

  test('rescan refuses a file library and an empty root', () async {
    final reports = <String>[];
    final video = File('${root.path}${Platform.pathSeparator}one.mkv')
      ..writeAsBytesSync(List<int>.filled(16, 1));
    final picker = _FakePicker(files: [
      PickedLocation(
        location: video.path,
        name: 'one.mkv',
        kind: LocalLibraryKind.file,
      ),
    ]);
    final actions = _actions(store, picker: picker, reports: reports);
    final library = (await actions.addFiles())!;

    expect(await actions.rescan(library), isNull);
    expect(reports, isEmpty);
  });

  test('removeLibrary only drops the index and never the user files',
      () async {
    final folder = Directory('${root.path}${Platform.pathSeparator}Keep')
      ..createSync(recursive: true);
    final file = File('${folder.path}${Platform.pathSeparator}keep.mkv')
      ..writeAsBytesSync(List<int>.filled(32, 1));
    final picker = _FakePicker(
      directory: PickedLocation(
        location: folder.path,
        name: 'Keep',
        kind: LocalLibraryKind.folder,
      ),
    );
    final actions = _actions(
      store,
      picker: picker,
      walker: InMemoryDirectoryWalker([_entry(folder.path, 'keep.mkv', 32)]),
    );
    final library = (await actions.addFolder())!;

    expect(await actions.removeLibrary(library), isTrue);
    expect(store.libraries, isEmpty);
    expect(file.existsSync(), isTrue);
    expect(folder.existsSync(), isTrue);
  });

  test('scan failures surface a scrubbed message, never the real path',
      () async {
    final reports = <String>[];
    final folder = Directory('${root.path}${Platform.pathSeparator}Broken')
      ..createSync(recursive: true);
    final picker = _FakePicker(
      directory: PickedLocation(
        location: folder.path,
        name: 'Broken',
        kind: LocalLibraryKind.folder,
      ),
    );
    final actions = _actions(
      store,
      picker: picker,
      walker: InMemoryDirectoryWalker(
        const [],
        error: FileSystemException('拒绝访问', '${folder.path}\\secret.mkv'),
      ),
      reports: reports,
    );

    // 扫描失败不撤库(用户确实挑了它,重扫还可能成功),但提示必须已经发出去,
    // 且提示里不能出现真实路径。
    final library = await actions.addFolder();
    expect(library, isNotNull);
    expect(store.libraries.length, 1);
    expect(store.items(library!.id), isEmpty);
    expect(reports, isNotEmpty);
    expect(reports.last, contains('扫描失败'));
    expect(reports.last, isNot(contains(folder.path)));
    expect(reports.last, isNot(contains('secret.mkv')));
  });

  test('scrubLocalPath hides every shape of absolute location', () {
    expect(scrubLocalPath('failed: F:\\Movies\\a.mkv'), 'failed: <路径>');
    expect(scrubLocalPath('failed: /sdcard/Movies/a.mkv'), 'failed: <路径>');
    expect(
      scrubLocalPath(
          'failed: content://com.android.externalstorage.documents/tree/x'),
      'failed: <位置>',
    );
  });
}

LocalLibraryActions _actions(
  LocalMediaStore store, {
  _FakePicker? picker,
  LocalDirectoryWalker? walker,
  List<String>? reports,
}) =>
    LocalLibraryActions(
      store: store,
      l10n: _l10n,
      picker: picker,
      windowsWalker: walker,
      windows: true,
      report: (message, kind) {
        reports?.add(message);
        expect(kind, isNotNull);
      },
    );

LocalFileEntry _entry(String directory, String name, int size) => LocalFileEntry(
      location: '$directory${Platform.pathSeparator}$name',
      name: name,
      directoryKey: directory,
      size: size,
    );

class _FakePicker implements LocalLocationPicker {
  _FakePicker({this.directory, this.files = const []});

  PickedLocation? directory;
  List<PickedLocation> files;
  int directoryCalls = 0;
  int fileCalls = 0;

  @override
  Future<PickedLocation?> pickDirectory() async {
    directoryCalls++;
    return directory;
  }

  @override
  Future<List<PickedLocation>> pickFiles() async {
    fileCalls++;
    return files;
  }
}
