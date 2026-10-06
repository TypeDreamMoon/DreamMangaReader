import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../core/local/local_episode_parser.dart';
import '../core/local/local_models.dart';

/// 索引根目录提供者。默认是 `<应用支持目录>/local-media`(规格 §5.2 的目录隔离),
/// 测试注入临时目录。
typedef LocalMediaRootProvider = Future<String> Function();

/// [LocalMediaException] 的原因码,供 UI 映射成 l10n 文案(Task 8),
/// 不要把 [LocalMediaException.message] 直接当用户可见文案。
enum LocalMediaError {
  duplicateLocation,
  libraryNotFound,
  itemNotFound,

  /// 改名字时给了个只有空白的名字(库名不能为空,条目名空着则表示恢复原名,
  /// 不走这条)。
  invalidName,
}

/// 本地媒体索引库的领域异常。
class LocalMediaException implements Exception {
  const LocalMediaException(this.reason, this.message);

  final LocalMediaError reason;
  final String message;

  @override
  String toString() => message;
}

/// 一次扫描合并结果的计数。
class LocalMediaScanSummary {
  const LocalMediaScanSummary({
    required this.added,
    required this.updated,
    required this.missing,
  });

  /// 本轮新入库的条目数。
  final int added;

  /// 命中已有条目并刷新元数据的条目数。
  final int updated;

  /// 索引里有、但本轮没扫到的条目数(它们**仍保留在索引里**,由 UI 灰显,规格 §8.4)。
  final int missing;

  @override
  String toString() =>
      'LocalMediaScanSummary(added: $added, updated: $updated, missing: $missing)';
}

/// 本地播放的媒体索引库:持有库与条目,负责落盘、去重、扫描结果合并与运行时可用性判断。
///
/// 设计见 docs/superpowers/specs/2026-09-30-local-playback-design.md §5.1/§5.2/§9。
///
/// - **只存索引,不复制媒体文件**:条目的 `location` 是 Windows 绝对路径或 Android
///   document uri,用户文件永远躺在原处(§5.5)。
/// - **落盘**:`<root>/index.json`,写 `index.json.tmp` → 备份 → rename 的原子替换
///   (屋风照 `AnimeDownloadStore`);旧索引保留一份为 `index.json.backup`,读档损坏时
///   先退备份、再退空库,绝不抛异常阻塞启动(§9)。
/// - **可用性不进 JSON**:文件是否存在由 [isAvailable] 在运行时推导(§5.1)。
/// - **续播位置不在这里**:权威是 `AnimeLibraryStore`(§5.4),本库只记「最近播放」时间。
class LocalMediaStore extends ChangeNotifier {
  LocalMediaStore({
    LocalMediaRootProvider? rootProvider,
    bool Function(String location)? existsProbe,
  })  : _rootProvider = rootProvider ?? _applicationSupportRoot,
        _existsProbe = existsProbe;

  /// 索引文件名(常量,不参与任何用户输入的拼接)。
  static const String _indexFileName = 'index.json';

  /// 索引 JSON 的版本号,读档时缺失字段一律取默认值(§9 向后兼容)。
  static const int _indexVersion = 1;

  /// Android SAF 的 uri 前缀:那条路线的存在性由桥的 stat / 播放前 openFd 判定。
  static const String _contentUriPrefix = 'content://';

  final LocalMediaRootProvider _rootProvider;
  final bool Function(String location)? _existsProbe;

  final Map<String, LocalLibrary> _libraries = {};
  final Map<String, LocalMediaItem> _items = {};

  Directory? _root;
  String? _loadWarning;
  bool _disposed = false;

  /// 最近一次 [load] 的降级提示(索引损坏 / 根目录不可用),正常时为 `null`。
  ///
  /// 只活在内存里、不落盘:它描述的是**这一次启动**的读档结果,不是库的状态。
  String? get loadWarning => _loadWarning;

  /// 已授权的本地库,按 `addedAt` 倒序(最近添加的在最前)。
  List<LocalLibrary> get libraries {
    final values = _libraries.values.toList()
      ..sort((left, right) {
        final byTime = right.addedAt.compareTo(left.addedAt);
        return byTime != 0 ? byTime : left.id.compareTo(right.id);
      });
    return List.unmodifiable(values);
  }

  /// 某个库的条目,按剧集顺序排序(见 [_compareItems])。
  List<LocalMediaItem> items(String libraryId) {
    final values = [
      for (final item in _items.values)
        if (item.libraryId == libraryId) item,
    ]..sort(_compareItems);
    return List.unmodifiable(values);
  }

  /// 全部条目(跨库),先按库 id 再按剧集顺序,便于统计与测试得到稳定结果。
  List<LocalMediaItem> get allItems {
    final values = _items.values.toList()
      ..sort((left, right) {
        final byLibrary = left.libraryId.compareTo(right.libraryId);
        return byLibrary != 0 ? byLibrary : _compareItems(left, right);
      });
    return List.unmodifiable(values);
  }

  LocalLibrary? library(String libraryId) => _libraries[libraryId];

  LocalMediaItem? item(String itemId) => _items[itemId];

  /// 读档。**任何情况下都不抛异常**:索引损坏 / 根目录不可用 / 备份也坏时,
  /// 都退化成空库并把原因写进 [loadWarning](§9)。
  Future<void> load() async {
    _libraries.clear();
    _items.clear();
    _loadWarning = null;
    try {
      final root = Directory(await _rootProvider());
      await root.create(recursive: true);
      if (_disposed) return;
      _root = root;
      final snapshot = await _recoverIndex(root);
      if (snapshot.corrupt) {
        _loadWarning = '本地媒体索引已损坏,已按空库启动,请重新扫描本地库。';
      } else {
        for (final library in snapshot.libraries) {
          _libraries[library.id] = library;
        }
        for (final item in snapshot.items) {
          if (!_libraries.containsKey(item.libraryId)) continue;
          _items[item.id] = item;
        }
      }
      // 正式索引缺失或损坏、靠备份救回来时,趁早把备份回写成正式索引,
      // 免得下一次读档又走一遍降级路径。回写失败不影响本次启动。
      if (snapshot.fromBackup && !_disposed) {
        try {
          await _persist();
        } catch (_) {
          // 只读介质等情况:内存里已经有数据了,下次变更时还会再试。
        }
      }
    } catch (error) {
      _libraries.clear();
      _items.clear();
      _loadWarning = '本地媒体索引读取失败,已按空库启动:$error';
    }
    _notify();
  }

  /// 新增一个本地库。
  ///
  /// [path]/[treeUri] 组成去重键(Windows 大小写不敏感,见 `localLibraryDedupeKey`),
  /// 已存在时抛 [LocalMediaError.duplicateLocation]。两者都为空是合法的
  /// ([LocalLibraryKind.file]:用户单独挑的一批文件没有共同根),此时不做去重。
  ///
  /// [items] 里 `location` 为空的条目会被丢弃;同一批里 `dedupeKey` 重复的只取第一条。
  Future<LocalLibrary> addLibrary({
    required String name,
    required LocalLibraryKind kind,
    String? path,
    String? treeUri,
    List<LocalMediaItem> items = const [],
  }) async {
    final windows = Platform.isWindows;
    final library = LocalLibrary(
      id: newLocalId(),
      name: name,
      kind: kind,
      path: _normalizedLocation(path),
      treeUri: _normalizedLocation(treeUri),
      addedAt: DateTime.now().millisecondsSinceEpoch,
      lastScannedAt: 0,
    );
    final key = library.dedupeKey(windows: windows);
    if (key.isNotEmpty &&
        _libraries.values
            .any((existing) => existing.dedupeKey(windows: windows) == key)) {
      throw const LocalMediaException(
        LocalMediaError.duplicateLocation,
        '该位置已在本地库中,无需重复添加',
      );
    }
    final nextLibraries = Map<String, LocalLibrary>.from(_libraries)
      ..[library.id] = library;
    final nextItems = Map<String, LocalMediaItem>.from(_items);
    final seen = <String>{};
    for (final item in items) {
      if (item.location.trim().isEmpty) continue;
      final adopted = _adopt(item, library.id);
      if (!seen.add(adopted.dedupeKey(windows: windows))) continue;
      nextItems[adopted.id] = adopted;
    }
    await _commit(libraries: nextLibraries, items: nextItems);
    return library;
  }

  /// 移除一个库:**只删索引,永不删除用户文件**(§5.5/§10)。
  ///
  /// M1 不提供删除源文件的能力;将来若要做,必须是另一次带二次确认的显式动作。
  /// 库不存在时抛 [LocalMediaError.libraryNotFound]。
  Future<void> removeLibrary(String libraryId) async {
    if (!_libraries.containsKey(libraryId)) {
      throw LocalMediaException(
        LocalMediaError.libraryNotFound,
        '本地库不存在:$libraryId',
      );
    }
    final nextLibraries = Map<String, LocalLibrary>.from(_libraries)
      ..remove(libraryId);
    final nextItems = Map<String, LocalMediaItem>.from(_items)
      ..removeWhere((_, item) => item.libraryId == libraryId);
    await _commit(libraries: nextLibraries, items: nextItems);
  }

  /// 把单个条目从索引里拿掉(库详情页的「移除条目」)—**只删索引,绝不碰用户文件**
  /// (§5.2/§10)。用户文件永远躺在原处,想真正删文件请走系统文件管理器。
  ///
  /// 幂等:`itemId` 不存在时静默返回 —— 移除一条已经被别的路径移掉的条目不该报错。
  /// 库本身不动:清到 0 条也不删库(库是用户授权的位置,条目只是它扫出来的东西)。
  Future<void> removeItem(String itemId) async {
    if (!_items.containsKey(itemId)) return;
    final nextItems = Map<String, LocalMediaItem>.from(_items)..remove(itemId);
    await _commit(libraries: _libraries, items: nextItems);
  }

  /// 改一个本地库的名字(规格 §5.6)。名字只影响展示:位置、条目、播放进度都不动。
  ///
  /// 只有空白的名字抛 [LocalMediaError.invalidName](库名是卡片上唯一的标识);
  /// 名字没变时直接返回,不写盘也不通知。
  Future<void> renameLibrary(String libraryId, String name) async {
    final library = _libraries[libraryId];
    if (library == null) {
      throw LocalMediaException(
        LocalMediaError.libraryNotFound,
        '本地库不存在:$libraryId',
      );
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const LocalMediaException(
        LocalMediaError.invalidName,
        '本地库名称不能为空',
      );
    }
    if (trimmed == library.name) return;
    final nextLibraries = Map<String, LocalLibrary>.from(_libraries)
      ..[libraryId] = library.copyWith(name: trimmed);
    await _commit(libraries: nextLibraries, items: _items);
  }

  /// 改一个条目的显示名(规格 §5.6)。
  ///
  /// [title] 只剩空白、或正好等于解析出来的 [LocalMediaItem.title],都表示
  /// **恢复原名**:清掉 `customTitle`,界面回到解析结果。名字存在 `customTitle`
  /// 而不是直接改 `title`,就是为了让重扫刷新 `title` 时不会把用户改的名字冲掉。
  ///
  /// 条目不存在时抛 [LocalMediaError.itemNotFound]。
  Future<void> renameItem(String itemId, String title) async {
    final item = _items[itemId];
    if (item == null) {
      throw LocalMediaException(
        LocalMediaError.itemNotFound,
        '本地条目不存在:$itemId',
      );
    }
    final trimmed = title.trim();
    final next = (trimmed.isEmpty || trimmed == item.title)
        ? item.copyWith(clearCustomTitle: true)
        : item.copyWith(customTitle: trimmed);
    if (next.customTitle == item.customTitle) return;
    final nextItems = Map<String, LocalMediaItem>.from(_items)..[itemId] = next;
    await _commit(libraries: _libraries, items: nextItems);
  }

  /// 合并一次扫描结果(§8.4 的「重新扫描」)。
  ///
  /// 按 `dedupeKey` 匹配库内已有条目:
  /// - 命中:**保留** `id`/`addedAt`/`lastPlayedAt`/`durationMs`/`thumbPath`
  ///   /`customTitle`(`id` 是进度记录的 `episodeId`,绝不能因为重扫而变;
  ///   用户改过的名字同理,刷新 `title` 不该把 `customTitle` 冲掉),刷新
  ///   `title`/`season`/`episode`/`sizeBytes`/`modifiedAt`/`subtitles`;
  /// - 未命中:用 [newLocalId] 新建;
  /// - 索引里有、本轮没扫到的条目**保留不删**,由 UI 用 [isAvailable] 灰显。
  ///
  /// 库不存在时抛 [LocalMediaError.libraryNotFound]。
  Future<LocalMediaScanSummary> applyScanResult(
    String libraryId,
    List<LocalMediaItem> scanned,
  ) async {
    final library = _libraries[libraryId];
    if (library == null) {
      throw LocalMediaException(
        LocalMediaError.libraryNotFound,
        '本地库不存在:$libraryId',
      );
    }
    final windows = Platform.isWindows;
    final existingByKey = <String, LocalMediaItem>{};
    for (final item in _items.values) {
      if (item.libraryId != libraryId) continue;
      existingByKey[item.dedupeKey(windows: windows)] = item;
    }
    final nextItems = Map<String, LocalMediaItem>.from(_items);
    final scannedKeys = <String>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    var added = 0;
    var updated = 0;
    for (final item in scanned) {
      final location = item.location.trim();
      if (location.isEmpty) continue;
      final key = item.dedupeKey(windows: windows);
      if (!scannedKeys.add(key)) continue;
      final previous = existingByKey[key];
      if (previous == null) {
        final adopted = _adopt(
          item,
          libraryId,
          id: newLocalId(),
          addedAt: item.addedAt > 0 ? item.addedAt : now,
        );
        nextItems[adopted.id] = adopted;
        added++;
        continue;
      }
      // copyWith 的 `?? this.x` 语义正好是「扫描值优先、缺失则保留旧值」,
      // 而 id/libraryId/addedAt/lastPlayedAt 不会被覆盖。
      nextItems[previous.id] = previous.copyWith(
        title: item.title,
        location: location,
        season: item.season,
        episode: item.episode,
        sizeBytes: item.sizeBytes,
        modifiedAt: item.modifiedAt,
        durationMs: item.durationMs,
        subtitles: item.subtitles,
        thumbPath: item.thumbPath,
      );
      updated++;
    }
    var missing = 0;
    for (final item in _items.values) {
      if (item.libraryId != libraryId) continue;
      if (scannedKeys.contains(item.dedupeKey(windows: windows))) continue;
      missing++;
    }
    final nextLibraries = Map<String, LocalLibrary>.from(_libraries)
      ..[libraryId] = library.copyWith(lastScannedAt: now);
    await _commit(libraries: nextLibraries, items: nextItems);
    return LocalMediaScanSummary(
        added: added, updated: updated, missing: missing);
  }

  /// 记录「最近播放」时间,并顺手用播放器报出的真实时长回填 `durationMs`
  /// (比 M1 扫描时的 `null` 准)。
  ///
  /// [position] 只是调用方与 `AnimeLibraryStore.saveProgress` 对齐的入参:
  /// 续播位置的权威是 `AnimeLibraryStore`(§5.4),本库**不存**播放位置。
  /// 条目不存在时抛 [LocalMediaError.itemNotFound]。
  Future<void> markPlayed(
    String itemId, {
    required Duration position,
    required Duration duration,
  }) async {
    final item = _items[itemId];
    if (item == null) {
      throw LocalMediaException(
        LocalMediaError.itemNotFound,
        '本地条目不存在:$itemId',
      );
    }
    final millis = duration.inMilliseconds;
    final nextItems = Map<String, LocalMediaItem>.from(_items)
      ..[itemId] = item.copyWith(
        durationMs: millis > 0 ? millis : null,
        lastPlayedAt: DateTime.now().millisecondsSinceEpoch,
      );
    await _commit(libraries: _libraries, items: nextItems);
  }

  /// 运行时判断条目是否还能播(§5.1:**结果绝不持久化**)。
  ///
  /// - `content://`(Android SAF):这里恒为 `true`,存在性由桥的 `stat`
  ///   和播放前的 `openFd` 判定 —— Dart 侧没法直接 stat 一个 document uri。
  /// - 其它:优先用注入的 [existsProbe](测试用),否则
  ///   `FileSystemEntity.typeSync(location) != notFound`。
  bool isAvailable(LocalMediaItem item) {
    final location = item.location.trim();
    if (location.isEmpty) return false;
    if (location.startsWith(_contentUriPrefix)) return true;
    final probe = _existsProbe;
    if (probe != null) return probe(location);
    try {
      return FileSystemEntity.typeSync(location) !=
          FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }

  /// 导出库结构(路径与标题),**不含文件本身**,也没有任何凭据(§5.2/§9)。
  ///
  /// [includeLocations] 为 `false` 时抹掉全部位置信息:条目的 `location`、字幕的
  /// `location`,以及库的 `path`/`treeUri`(§10:用户目录名可能含真实姓名)。
  /// 注意这种导出与 [importData] 不搭:没有位置就没有去重键,导入时会被跳过,
  /// 换机只能重新挑目录。
  Map<String, Object?> exportData({bool includeLocations = true}) => {
        'version': _indexVersion,
        'libraries': [
          for (final library in libraries)
            _libraryJson(library, includeLocations: includeLocations),
        ],
      };

  /// 导入合并:**同 `dedupeKey` 跳过,不覆盖已有条目**;库与条目都重新发 id,
  /// 免得把外部 id 带进进度表(`episodeId`)。
  ///
  /// 没有位置信息的库(见 [exportData] 的 `includeLocations: false`)无法定位文件,
  /// 也没有去重键,一律跳过。结构不对时直接忽略,不抛异常。
  Future<void> importData(Map<String, Object?> data) async {
    final rawLibraries = data['libraries'];
    if (rawLibraries is! List) return;
    final windows = Platform.isWindows;
    final nextLibraries = Map<String, LocalLibrary>.from(_libraries);
    final nextItems = Map<String, LocalMediaItem>.from(_items);
    final knownKeys = {
      for (final library in _libraries.values)
        library.dedupeKey(windows: windows),
    };
    for (final entry in rawLibraries) {
      if (entry is! Map) continue;
      final parsed = LocalLibrary.fromJson(entry);
      final key = parsed.dedupeKey(windows: windows);
      if (key.isEmpty || !knownKeys.add(key)) continue;
      final id = newLocalId();
      nextLibraries[id] = _libraryWithId(
        parsed,
        id,
        addedAt: parsed.addedAt > 0
            ? parsed.addedAt
            : DateTime.now().millisecondsSinceEpoch,
      );
      for (final item in LocalMediaItem.listFromJson(entry['items'])) {
        if (item.location.trim().isEmpty) continue;
        final adopted = _adopt(item, id, id: newLocalId());
        nextItems[adopted.id] = adopted;
      }
    }
    if (nextLibraries.length == _libraries.length &&
        nextItems.length == _items.length) {
      return;
    }
    await _commit(libraries: nextLibraries, items: nextItems);
  }

  // --- 落盘 ---------------------------------------------------------------

  /// 索引文件本身(常量名,不拼任何用户输入)。
  File _indexFile(Directory root) =>
      File('${root.path}${Platform.pathSeparator}$_indexFileName');

  /// 解析根目录,`load()` 失败过(或还没跑过)时也能让变更方法自己再试一次。
  Future<Directory> _ensureRoot() async {
    final existing = _root;
    if (existing != null) return existing;
    final root = Directory(await _rootProvider());
    await root.create(recursive: true);
    _root = root;
    return root;
  }

  /// 原子写:写 `index.json.tmp` → 旧索引挪成 `index.json.backup` → rename。
  ///
  /// rename 失败时把备份还原回 `index.json` 再抛(屋风照 `AnimeDownloadStore`)。
  /// 成功后**保留**备份:§5.2 要求留一份,而且 [load] 的「正式索引坏了退备份」
  /// 这条路径靠它才有意义。
  Future<void> _persist() async {
    final root = await _ensureRoot();
    final index = _indexFile(root);
    final temporary = File('${index.path}.tmp');
    final backup = File('${index.path}.backup');
    await temporary.writeAsString(
      // 落盘用的就是「带位置的全量导出」,与 [exportData] 同一份结构。
      jsonEncode(exportData()),
      encoding: utf8,
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await index.exists()) await index.rename(backup.path);
    try {
      await temporary.rename(index.path);
    } catch (_) {
      if (!await index.exists() && await backup.exists()) {
        await backup.rename(index.path);
      }
      rethrow;
    }
  }

  /// 读索引:优先 `index.json`,坏了或不在就退 `index.json.backup`。
  ///
  /// 返回的快照带 `corrupt` 标记:两份都在、都读不出来时才为 `true`
  /// (这才是 §9 里「退空库 + 提示重新扫描」的情形;全新安装不算损坏)。
  Future<_IndexSnapshot> _recoverIndex(Directory root) async {
    final index = _indexFile(root);
    final backup = File('${index.path}.backup');
    var sawCorrupt = false;
    for (final candidate in <File>[index, backup]) {
      if (!await candidate.exists()) continue;
      final snapshot =
          await _readIndex(candidate, fromBackup: candidate != index);
      if (!snapshot.corrupt) return snapshot;
      sawCorrupt = true;
    }
    return _IndexSnapshot(corrupt: sawCorrupt);
  }

  Future<_IndexSnapshot> _readIndex(File file,
      {bool fromBackup = false}) async {
    try {
      return _parseSnapshot(
        await file.readAsString(encoding: utf8),
        fromBackup: fromBackup,
      );
    } catch (_) {
      return _IndexSnapshot(corrupt: true, fromBackup: fromBackup);
    }
  }

  /// 解析索引 JSON:结构不对(不是对象 / 没有 `libraries` 数组)算损坏。
  ///
  /// 单个库里读不动的条目直接跳过,不牵连整个索引。
  _IndexSnapshot _parseSnapshot(String raw, {required bool fromBackup}) {
    final decoded = jsonDecode(raw);
    // 不是对象、或没有 `libraries` 数组 → 整份索引算损坏(两种情形处理相同)。
    final rawLibraries = decoded is Map ? decoded['libraries'] : null;
    if (rawLibraries is! List) {
      return _IndexSnapshot(corrupt: true, fromBackup: fromBackup);
    }
    final libraries = <LocalLibrary>[];
    final items = <LocalMediaItem>[];
    final knownIds = <String>{};
    for (final entry in rawLibraries) {
      if (entry is! Map) continue;
      final parsed = LocalLibrary.fromJson(entry);
      // id 会参与 M2 缩略图 / 路线 B 导入目录的落盘拼接,读回时按 §10 再硬化一次。
      final id = _safeId(parsed.id);
      if (!knownIds.add(id)) continue;
      libraries.add(
        id == parsed.id ? parsed : _libraryWithId(parsed, id),
      );
      for (final item in LocalMediaItem.listFromJson(entry['items'])) {
        if (item.location.trim().isEmpty) continue;
        items.add(_adopt(item, id, id: _safeId(item.id)));
      }
    }
    return _IndexSnapshot(
      libraries: libraries,
      items: items,
      fromBackup: fromBackup,
    );
  }

  Map<String, Object?> _libraryJson(
    LocalLibrary library, {
    required bool includeLocations,
  }) {
    final json = library.toJson();
    json['items'] = [
      for (final item in items(library.id))
        includeLocations ? item.toJson() : _locationlessJson(item),
    ];
    if (!includeLocations) {
      json.remove('path');
      json.remove('treeUri');
    }
    return json;
  }

  /// 抹掉条目里所有位置信息(字幕也带 `location`,一并去掉)。
  Map<String, Object?> _locationlessJson(LocalMediaItem item) {
    final json = item.toJson();
    json.remove('location');
    json.remove('subtitles');
    return json;
  }

  /// 先改内存再落盘,落盘失败就回滚并 rethrow —— 别让内存里的库和磁盘上的索引对不上。
  Future<void> _commit({
    required Map<String, LocalLibrary> libraries,
    required Map<String, LocalMediaItem> items,
  }) async {
    final previousLibraries = Map<String, LocalLibrary>.from(_libraries);
    final previousItems = Map<String, LocalMediaItem>.from(_items);
    // 先复制再清空:调用方会把内部 map 本身当参数传进来(如 [markPlayed] 传 `_libraries`,
    // 因为那条路径不动库),直接 `clear()` + `addAll(来源)` 会先清空来源,结果两边都空。
    final incomingLibraries = Map<String, LocalLibrary>.of(libraries);
    final incomingItems = Map<String, LocalMediaItem>.of(items);
    _libraries
      ..clear()
      ..addAll(incomingLibraries);
    _items
      ..clear()
      ..addAll(incomingItems);
    try {
      await _persist();
    } catch (_) {
      _libraries
        ..clear()
        ..addAll(previousLibraries);
      _items
        ..clear()
        ..addAll(previousItems);
      rethrow;
    }
    _notify();
  }

  // --- 纯函数工具 ---------------------------------------------------------

  /// 换一个 id 重建库。[LocalLibrary.copyWith] 不动 id,而 id 会参与落盘拼接,
  /// 所以读档与导入这两条「外来的 id 不可信」的路径都得整只重建。
  LocalLibrary _libraryWithId(LocalLibrary library, String id, {int? addedAt}) =>
      LocalLibrary(
        id: id,
        name: library.name,
        kind: library.kind,
        path: library.path,
        treeUri: library.treeUri,
        addedAt: addedAt ?? library.addedAt,
        lastScannedAt: library.lastScannedAt,
        coverThumb: library.coverThumb,
      );

  /// 把条目归属到 [libraryId];[id] 为空时按需发新 id。
  LocalMediaItem _adopt(
    LocalMediaItem item,
    String libraryId, {
    String? id,
    int? addedAt,
  }) =>
      LocalMediaItem(
        id: id ?? (item.id.isEmpty ? newLocalId() : item.id),
        libraryId: libraryId,
        title: item.title,
        location: item.location.trim(),
        season: item.season,
        episode: item.episode,
        sizeBytes: item.sizeBytes,
        modifiedAt: item.modifiedAt,
        durationMs: item.durationMs,
        subtitles: item.subtitles,
        thumbPath: item.thumbPath,
        customTitle: item.customTitle,
        addedAt: addedAt ?? item.addedAt,
        lastPlayedAt: item.lastPlayedAt,
      );

  /// 条目在 `location` 里的原始文件名,只做排序决胜用。
  ///
  /// Windows 反斜杠与 uri 的正斜杠统一处理;Android 的 uri 段是百分号编码的,
  /// 这里不做解码(§9:索引入库前后都不转码)。
  String _baseName(String location) {
    final normalized = location.replaceAll(r'\', '/');
    final cut = normalized.lastIndexOf('/');
    final name = cut < 0 ? normalized : normalized.substring(cut + 1);
    return name.isEmpty ? normalized : name;
  }

  /// 索引里的 id 会参与落盘拼接(M2 缩略图、路线 B 导入目录),
  /// 读回时过一遍 [localSafeName];结果为空、或仍是 `.`/`..` 这种相对段时换新 id。
  String _safeId(String raw) {
    final safe = localSafeName(raw);
    if (safe.isEmpty || safe == '.' || safe == '..') return newLocalId();
    return safe;
  }

  String? _normalizedLocation(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// 排序:先按解析出的季集,再按标题,最后按 `location` 兜底保证全序稳定。
  ///
  /// 条目里已经存了 season/episode,不必每条重新解析;只有标题缺失(旧索引/异常写入)
  /// 时才退回 [parseMediaFileName] 解析一次文件名。
  int _compareItems(LocalMediaItem a, LocalMediaItem b) {
    final nameA = _baseName(a.location);
    final nameB = _baseName(b.location);
    final order = compareEpisodes(
      a: _parsedOf(a, nameA),
      nameA: nameA,
      b: _parsedOf(b, nameB),
      nameB: nameB,
    );
    if (order != 0) return order;
    final byTitle = a.title.compareTo(b.title);
    return byTitle != 0 ? byTitle : a.location.compareTo(b.location);
  }

  ParsedMediaName _parsedOf(LocalMediaItem item, String fileName) =>
      item.title.isNotEmpty
          ? ParsedMediaName(
              title: item.title,
              season: item.season,
              episode: item.episode,
            )
          : parseMediaFileName(fileName);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 一次读档的结果。[corrupt] 只在两份索引都读不出来时为 `true`。
class _IndexSnapshot {
  const _IndexSnapshot({
    this.libraries = const [],
    this.items = const [],
    this.corrupt = false,
    this.fromBackup = false,
  });

  final List<LocalLibrary> libraries;
  final List<LocalMediaItem> items;
  final bool corrupt;
  final bool fromBackup;
}

Future<String> _applicationSupportRoot() async {
  final support = await getApplicationSupportDirectory();
  return '${support.path}${Platform.pathSeparator}local-media';
}

/// 把 [LocalMediaStore] 下发给页面。`InheritedNotifier`:依赖它的页面会在索引变化时重建。
///
/// 装配点见 lib/app/app.dart(`LocalMediaScope` 与其它内容库 Scope 同层,在
/// `MaterialApp` 之上,所以任何路由/页面都能拿到)。
class LocalMediaScope extends InheritedNotifier<LocalMediaStore> {
  const LocalMediaScope({
    super.key,
    required LocalMediaStore store,
    required super.child,
  }) : super(notifier: store);

  static LocalMediaStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LocalMediaScope>();
    assert(scope != null, 'LocalMediaScope not found in context');
    return scope!.notifier!;
  }

  /// 只取一次、不建立依赖(点击回调里用,避免无谓重建)。
  static LocalMediaStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<LocalMediaScope>();
    assert(scope != null, 'LocalMediaScope not found in context');
    return scope!.notifier!;
  }
}
